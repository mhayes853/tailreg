import Foundation
import Hummingbird
import Logging
import SQLiteData
import ServiceLifecycle
import TailregCore
import UUIDV7
import UnixSignals

/// The scheme the MUX is reached on from outside.
///
/// Tailscale terminates TLS in front of a project MUX, so `https` is the normal case; `http` is
/// for a MUX reached directly, where a browser would refuse the cookies TLS allows.
public enum PublicScheme: String, Sendable {
  case https
  case http
}

public struct Multiplexer: Sendable {
  public struct Configuration: Equatable, Sendable {
    public static let defaultAdminPort = PortNumber(rawValue: 9_100)!
    public static let defaultIngressPort = PortNumber(rawValue: 9_000)!

    public let adminHost: String
    public let adminPort: PortNumber
    public let id: UUIDV7
    public let ingressHost: String
    public let ingressPort: PortNumber
    public let pathPolicy: MuxPathPolicy
    public let unmatchedPathPolicy: UnmatchedPathPolicy
    public let routingCookieName: String
    public let publicScheme: PublicScheme
    public let capturedHeaderPolicy: CapturedHeaderPolicy

    /// Whether the routing cookie may be marked `Secure`, which a browser only honors over TLS.
    public var secureCookies: Bool { publicScheme == .https }

    public init(
      adminHost: String = "127.0.0.1",
      adminPort: PortNumber = Configuration.defaultAdminPort,
      id: UUIDV7 = UUIDV7(),
      ingressHost: String = "127.0.0.1",
      ingressPort: PortNumber = Configuration.defaultIngressPort,
      pathPolicy: MuxPathPolicy = MuxPathPolicy(),
      unmatchedPathPolicy: UnmatchedPathPolicy = .reject,
      routingCookieName: String? = nil,
      publicScheme: PublicScheme = .https,
      capturedHeaderPolicy: CapturedHeaderPolicy = .redactSensitiveValues
    ) {
      self.adminHost = adminHost
      self.adminPort = adminPort
      self.id = id
      self.ingressHost = ingressHost
      self.ingressPort = ingressPort
      self.pathPolicy = pathPolicy
      self.unmatchedPathPolicy = unmatchedPathPolicy
      self.routingCookieName = routingCookieName ?? publicScheme.routingCookieName(muxID: id)
      self.publicScheme = publicScheme
      self.capturedHeaderPolicy = capturedHeaderPolicy
    }
  }

  public let configuration: Configuration
  public let database: any DatabaseWriter
  public let captureRecorder: CaptureRecorder

  /// Creates an ephemeral MUX backed by an in-memory database.
  public init(configuration: Configuration = Configuration()) throws {
    self.init(
      configuration: configuration,
      database: try openTailregDatabase(path: ":memory:", kind: .queue)
    )
  }

  public init(
    configuration: Configuration = Configuration(),
    database: any DatabaseWriter,
    classificationRefiner: (any RequestClassificationRefining)? = nil
  ) {
    self.configuration = configuration
    self.database = database
    self.captureRecorder = CaptureRecorder(
      muxID: configuration.id,
      database: database,
      classificationRefiner: classificationRefiner
    )
  }

  /// The public ingress listener, optionally sharing its lifetime with `services`.
  ///
  /// Anything a MUX process runs beside ingress — the upstreams an E2E fixture stands up, a
  /// capture admin listener — belongs to the same service group, so one shutdown stops them all.
  public func buildIngressApplication(
    services: [any Service] = []
  ) -> Application<MuxIngressResponder> {
    Application(
      responder: MuxIngressResponder(
        database: database,
        muxID: configuration.id,
        pathPolicy: configuration.pathPolicy,
        unmatchedPathPolicy: configuration.unmatchedPathPolicy,
        cookieName: configuration.routingCookieName,
        publicScheme: configuration.publicScheme,
        capturedHeaderPolicy: configuration.capturedHeaderPolicy,
        captureRecorder: captureRecorder
      ),
      configuration: ApplicationConfiguration(
        address: .hostname(configuration.ingressHost, port: configuration.ingressPort.intValue),
        serverName: "tailreg-mux-ingress"
      ),
      services: services
    )
  }

  public func prepare() async throws {
    try await database.write { database in
      try MuxRouteQueries.prepare(muxID: configuration.id, in: database)
    }
  }

  public func routes() async throws -> [MultiplexerBinding] {
    try await database.read { database in
      return try MuxRouteQueries.live(muxID: configuration.id, in: database)
        .map { try MultiplexerBinding(record: $0, pathPolicy: configuration.pathPolicy) }
    }
  }

  public func binding(route: MuxRouteName) async throws -> MultiplexerBinding? {
    try await database.read { database in
      return try MuxRouteQueries.live(muxID: configuration.id, route: route, in: database)
        .map { try MultiplexerBinding(record: $0, pathPolicy: configuration.pathPolicy) }
    }
  }

  @discardableResult
  public func registerRoute(
    name: String,
    route: MuxRouteName? = nil,
    upstream: URL,
    pathMode: MuxRoutePathMode = .stripRoutePrefix
  ) async throws -> MultiplexerBinding {
    try await database.write { database in
      try MuxRouteQueries.prepare(muxID: configuration.id, in: database)
      return try MultiplexerBinding(
        record: MuxRouteQueries.register(
          muxID: configuration.id,
          name: name,
          requestedRoute: route,
          upstream: upstream,
          pathMode: pathMode,
          in: database
        ),
        pathPolicy: configuration.pathPolicy
      )
    }
  }

  @discardableResult
  public func updateRoute(
    route: MuxRouteName,
    upstream: URL,
    pathMode: MuxRoutePathMode? = nil
  ) async throws -> MultiplexerBinding {
    try await database.write { database in
      try MuxRouteQueries.prepare(muxID: configuration.id, in: database)
      return try MultiplexerBinding(
        record: MuxRouteQueries.update(
          muxID: configuration.id,
          route: route,
          upstream: upstream,
          pathMode: pathMode,
          in: database
        ),
        pathPolicy: configuration.pathPolicy
      )
    }
  }

  @discardableResult
  public func unregisterRoute(route: MuxRouteName) async throws -> MultiplexerBinding? {
    try await database.write { database in
      try MuxRouteQueries.prepare(muxID: configuration.id, in: database)
      return try MuxRouteQueries.unregister(muxID: configuration.id, route: route, in: database)
        .map { try MultiplexerBinding(record: $0, pathPolicy: configuration.pathPolicy) }
    }
  }

  public func run() async throws {
    try await prepare()
    let services: [any Service] = [buildApplication(), buildIngressApplication()]
    let group = ServiceGroup(
      configuration: .init(
        services: services,
        gracefulShutdownSignals: [.sigterm, .sigint],
        logger: Logger(label: "tailreg-mux")
      )
    )
    // The recorder is still holding a batch that has not reached the database, so it is drained
    // on the way out whether the group stopped cleanly or failed.
    let failure: (any Error)?
    do {
      try await group.run()
      failure = nil
    } catch {
      failure = error
    }
    await captureRecorder.finish()
    if let failure { throw failure }
  }
}

extension PublicScheme {
  /// The routing cookie's name when nothing overrides it.
  ///
  /// A browser rejects a `__Host-` cookie that is not `Secure`, so a plaintext MUX cannot use the
  /// prefix that would otherwise pin the cookie to this host and path.
  fileprivate func routingCookieName(muxID: UUIDV7) -> String {
    switch self {
    case .https: "__Host-tailreg-route-\(muxID.uuidString.lowercased())"
    case .http: "tailreg-route-\(muxID.uuidString.lowercased())"
    }
  }
}
