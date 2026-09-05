import Foundation
import Hummingbird
import Logging
import SQLiteData
import ServiceLifecycle
import TailregCore
import UUIDV7
import UnixSignals

public struct Multiplexer: Sendable {
  public struct Configuration: Equatable, Sendable {
    public var adminHost: String
    public var adminPort: Int
    public var id: UUIDV7
    public var ingressHost: String
    public var ingressPort: Int
    public var pathPolicy: MuxPathPolicy
    public var unmatchedPathPolicy: UnmatchedPathPolicy
    public var routingCookieName: String
    public var secureCookies: Bool
    public var capturedHeaderPolicy: CapturedHeaderPolicy

    public init(
      adminHost: String = "127.0.0.1",
      adminPort: Int = 9100,
      id: UUIDV7 = UUIDV7(),
      ingressHost: String = "127.0.0.1",
      ingressPort: Int = 9000,
      pathPolicy: MuxPathPolicy = MuxPathPolicy(),
      unmatchedPathPolicy: UnmatchedPathPolicy = .reject,
      routingCookieName: String? = nil,
      secureCookies: Bool = true,
      capturedHeaderPolicy: CapturedHeaderPolicy = .redactSensitiveValues
    ) {
      self.adminHost = adminHost
      self.adminPort = adminPort
      self.id = id
      self.ingressHost = ingressHost
      self.ingressPort = ingressPort
      self.pathPolicy = pathPolicy
      self.unmatchedPathPolicy = unmatchedPathPolicy
      self.routingCookieName =
        routingCookieName
        ?? "__Host-tailreg-route-\(id.uuidString.lowercased())"
      self.secureCookies = secureCookies
      self.capturedHeaderPolicy = capturedHeaderPolicy
    }
  }

  public let configuration: Configuration
  public let database: any DatabaseWriter
  public let captureRecorder: CaptureRecorder?

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

  public func buildApplication() -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
    router.get("/status") { _, _ in
      MultiplexerStatus(status: "ok", id: configuration.id)
    }
    router.get("/routes") { _, _ in
      try await routes().map(MuxRouteResponse.init)
    }
    router.post("/routes") { request, context -> MuxRouteResponse in
      let registration: MuxRouteRegistrationRequest
      do {
        registration = try await request.decode(
          as: MuxRouteRegistrationRequest.self,
          context: context
        )
      } catch {
        throw HTTPError(.badRequest)
      }
      guard let upstream = URL(string: registration.upstreamURL) else {
        throw HTTPError(.badRequest)
      }
      do {
        return try await MuxRouteResponse(
          registerRoute(
            name: registration.name,
            route: registration.route,
            upstream: upstream,
            pathMode: registration.pathMode
          )
        )
      } catch MuxRouteError.invalidName, MuxRouteError.invalidRoute,
        MuxRouteError.routeAlreadyExists, MuxRouteError.invalidUpstream
      {
        throw HTTPError(.badRequest)
      }
    }
    router.put("/routes/:route") { request, context -> MuxRouteResponse in
      let route = try context.parameters.require("route")
      let update: MuxRouteUpdateRequest
      do {
        update = try await request.decode(as: MuxRouteUpdateRequest.self, context: context)
      } catch {
        throw HTTPError(.badRequest)
      }
      guard let upstream = URL(string: update.upstreamURL) else {
        throw HTTPError(.badRequest)
      }
      do {
        return try await MuxRouteResponse(
          updateRoute(route: route, upstream: upstream, pathMode: update.pathMode)
        )
      } catch MuxRouteError.routeNotFound {
        throw HTTPError(.notFound)
      } catch MuxRouteError.invalidUpstream {
        throw HTTPError(.badRequest)
      }
    }
    router.delete("/routes/:route") { _, context -> HTTPResponse.Status in
      let route = try context.parameters.require("route")
      guard try await unregisterRoute(route: route) != nil else {
        throw HTTPError(.notFound)
      }
      return .noContent
    }

    return Application(
      router: router,
      configuration: ApplicationConfiguration(
        address: .hostname(configuration.adminHost, port: configuration.adminPort),
        serverName: "tailreg-mux"
      )
    )
  }

  public func buildIngressApplication() -> Application<MuxIngressResponder> {
    Application(
      responder: MuxIngressResponder(
        database: database,
        muxID: configuration.id,
        pathPolicy: configuration.pathPolicy,
        unmatchedPathPolicy: configuration.unmatchedPathPolicy,
        cookieName: configuration.routingCookieName,
        secureCookies: configuration.secureCookies,
        capturedHeaderPolicy: configuration.capturedHeaderPolicy,
        captureRecorder: captureRecorder
      ),
      configuration: ApplicationConfiguration(
        address: .hostname(configuration.ingressHost, port: configuration.ingressPort),
        serverName: "tailreg-mux-ingress"
      )
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

  public func binding(route: String) async throws -> MultiplexerBinding? {
    try await database.read { database in
      return try MuxRouteQueries.live(muxID: configuration.id, route: route, in: database)
        .map { try MultiplexerBinding(record: $0, pathPolicy: configuration.pathPolicy) }
    }
  }

  @discardableResult
  public func registerRoute(
    name: String,
    route: String? = nil,
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
    route: String,
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
  public func unregisterRoute(route: String) async throws -> MultiplexerBinding? {
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
    do {
      try await group.run()
      await captureRecorder?.finish()
    } catch {
      await captureRecorder?.finish()
      throw error
    }
  }
}
