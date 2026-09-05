import Foundation
import TOML
import TailregCore
import TailregMultiplexer

public struct ProjectSpecification: Equatable, Sendable {
  public let name: String?
  public let applications: [ApplicationSpecification]

  public static func load(from file: URL) throws -> ProjectSpecification {
    let source = try String(contentsOf: file, encoding: .utf8)
    let document = try TOMLDecoder().decode(Document.self, from: source)
    let applications = try document.apps
      .map { name, raw in
        try ApplicationSpecification(
          name: name,
          raw: raw,
          projectRoot: file.deletingLastPathComponent()
        )
      }
      .sorted { $0.name < $1.name }
    let specification = ProjectSpecification(
      name: document.project?.name,
      applications: applications
    )
    try specification.validate()
    return specification
  }

  public func selected(_ names: [String]) throws -> [[ApplicationSpecification]] {
    let byName = Dictionary(uniqueKeysWithValues: applications.map { ($0.name, $0) })
    let roots = names.isEmpty ? Set(byName.keys) : Set(names)
    for name in roots where byName[name] == nil {
      throw ProjectSpecificationError.unknownApplication(name)
    }

    var included = roots
    var pending = Array(roots)
    while let name = pending.popLast(), let application = byName[name] {
      for dependency in application.dependencies where included.insert(dependency).inserted {
        pending.append(dependency)
      }
    }

    var remaining = included
    var completed: Set<String> = []
    var levels: [[ApplicationSpecification]] = []
    while !remaining.isEmpty {
      let ready = remaining.compactMap { byName[$0] }
        .filter { Set($0.dependencies).isSubset(of: completed) }
        .sorted { $0.name < $1.name }
      guard !ready.isEmpty else { throw ProjectSpecificationError.dependencyCycle }
      levels.append(ready)
      let readyNames = Set(ready.map(\.name))
      remaining.subtract(readyNames)
      completed.formUnion(readyNames)
    }
    return levels
  }

  private func validate() throws {
    guard !applications.isEmpty else { throw ProjectSpecificationError.noApplications }
    let names = Set(applications.map(\.name))
    let routes = applications.compactMap { $0.exposure?.route }
    guard Set(routes).count == routes.count else { throw ProjectSpecificationError.duplicateRoute }
    for application in applications {
      for dependency in application.dependencies where !names.contains(dependency) {
        throw ProjectSpecificationError.unknownDependency(
          application: application.name,
          dependency: dependency
        )
      }
    }
    _ = try selected([])
  }

  private struct Document: Decodable {
    var project: Project?
    var apps: [String: RawApplication]
  }

  private struct Project: Decodable {
    var name: String?
  }

  fileprivate struct RawApplication: Decodable {
    var route: String?
    var port: PortNumber?
    var attach: String?
    var command: [String]?
    var workingDirectory: String?
    var dependsOn: [String]?
    var environment: [String: String]?
    var expose: Bool?
    var preserveRoutePrefix: Bool?

    enum CodingKeys: String, CodingKey {
      case route, port, attach, command, environment, expose
      case workingDirectory = "working_directory"
      case dependsOn = "depends_on"
      case preserveRoutePrefix = "preserve_route_prefix"
    }
  }
}

/// One application in a project's desired state.
///
/// The combinations that used to be validated are now unrepresentable: an application has
/// exactly one source of traffic, and an exposed one has an upstream derived from that source
/// rather than an optional that every consumer had to re-check.
public struct ApplicationSpecification: Equatable, Sendable {
  /// Where an application's traffic comes from.
  public enum Source: Equatable, Sendable {
    /// A command Tailreg launches and supervises, listening on `port` if it listens at all.
    case command(ProcessCommand, port: PortNumber?)
    /// Someone else's process, reachable at a loopback URL. Never signalled.
    case attached(LoopbackURL)

    /// What a route for this source would proxy to, if there is anything to proxy to.
    fileprivate var upstream: LoopbackURL? {
      switch self {
      case .command(_, let port): port.map(LoopbackURL.init(port:))
      case .attached(let url): url
      }
    }
  }

  /// How an exposed application is published. Nil is `expose = false`.
  public struct Exposure: Equatable, Sendable {
    /// The stable route name, or nil to let the MUX allocate one.
    public let route: MuxRouteName?
    public let pathMode: MuxRoutePathMode
    public let upstream: LoopbackURL
  }

  public let name: String
  public let source: Source
  public let exposure: Exposure?
  public let dependencies: [String]

  public var command: ProcessCommand? {
    guard case .command(let command, _) = source else { return nil }
    return command
  }

  /// The port readiness is judged on: the one a launched command was told to listen on, or the
  /// one an attached upstream already answers on.
  public var listenerPort: PortNumber? {
    switch source {
    case .command(_, let port): port
    case .attached(let url): url.port
    }
  }

  public var isExposed: Bool { exposure != nil }

  public var ownership: ApplicationOwnership {
    switch source {
    case .command: .managed
    case .attached: .attached
    }
  }

  public init(
    name: String,
    source: Source,
    route: MuxRouteName? = nil,
    pathMode: MuxRoutePathMode = .stripRoutePrefix,
    isExposed: Bool = true,
    dependencies: [String] = []
  ) throws {
    guard !name.isEmpty else { throw ProjectSpecificationError.invalidApplicationName }
    self.name = name
    self.source = source
    self.dependencies = dependencies
    guard isExposed else {
      self.exposure = nil
      return
    }
    // The one thing a source cannot supply on its own: a command that never says where it
    // listens has nothing for a route to point at.
    guard let upstream = source.upstream else {
      throw ProjectSpecificationError.missingPort(name)
    }
    self.exposure = Exposure(route: route, pathMode: pathMode, upstream: upstream)
  }

  /// Reads one `[apps.NAME]` table.
  ///
  /// Every error here is about the raw fields rather than the resulting application: the shape
  /// the type guarantees is exactly what the file may fail to describe.
  fileprivate init(
    name: String,
    raw: ProjectSpecification.RawApplication,
    projectRoot: URL
  ) throws {
    let workingDirectory =
      raw.workingDirectory.map {
        URL(fileURLWithPath: $0, relativeTo: projectRoot).standardizedFileURL
      } ?? projectRoot
    let command = try raw.command.map { arguments -> ProcessCommand in
      guard let executable = arguments.first else {
        throw ProjectSpecificationError.emptyCommand(name)
      }
      return ProcessCommand(
        executable: executable,
        arguments: Array(arguments.dropFirst()),
        workingDirectory: workingDirectory,
        environment: raw.environment ?? [:]
      )
    }
    let source: Source
    switch (command, raw.attach) {
    case (let command?, nil):
      source = .command(command, port: raw.port)
    case (nil, let attach?):
      guard let url = URL(string: attach), let loopback = LoopbackURL(url) else {
        throw ProjectSpecificationError.invalidAttachURL(name)
      }
      // The URL already says where the upstream listens; a second port could only disagree, and
      // whichever one won, readiness would be judged on a port unrelated to the route.
      guard raw.port == nil else { throw ProjectSpecificationError.portWithAttach(name) }
      source = .attached(loopback)
    case (nil, nil):
      throw ProjectSpecificationError.missingCommandOrAttach(name)
    case (.some, .some):
      throw ProjectSpecificationError.commandAndAttach(name)
    }
    try self.init(
      name: name,
      source: source,
      // Parsed here rather than in `RawApplication`, where the name of the table the route was
      // written in — and so the subject of the error a bad one has to report — is out of scope.
      route: try raw.route.map { route in
        guard let route = MuxRouteName(rawValue: route) else {
          throw ProjectSpecificationError.invalidRoute(application: name, route: route)
        }
        return route
      },
      pathMode: raw.preserveRoutePrefix == true ? .preserveRoutePrefix : .stripRoutePrefix,
      isExposed: raw.expose ?? true,
      dependencies: raw.dependsOn ?? []
    )
  }
}

public enum ProjectSpecificationError: Error, Equatable, CustomStringConvertible, Sendable {
  case noApplications
  case duplicateRoute
  case invalidApplicationName
  case emptyCommand(String)
  case missingCommandOrAttach(String)
  case commandAndAttach(String)
  case missingPort(String)
  case invalidAttachURL(String)
  case portWithAttach(String)
  case invalidRoute(application: String, route: String)
  case unknownApplication(String)
  case unknownDependency(application: String, dependency: String)
  case dependencyCycle

  public var description: String {
    switch self {
    case .noApplications: "tailreg.toml does not define any applications"
    case .duplicateRoute: "application routes must be unique"
    case .invalidApplicationName: "application names cannot be empty"
    case .emptyCommand(let app): "application '\(app)' has an empty command"
    case .missingCommandOrAttach(let app):
      "application '\(app)' needs either command or attach"
    case .commandAndAttach(let app):
      "application '\(app)' cannot define both command and attach"
    case .missingPort(let app): "exposed application '\(app)' needs a port"
    case .invalidAttachURL(let app): "application '\(app)' has a non-loopback attach URL"
    case .portWithAttach(let app): "application '\(app)' attaches to a URL; port has no effect"
    case .invalidRoute(let app, let route): "application '\(app)' has invalid route '\(route)'"
    case .unknownApplication(let app): "unknown application '\(app)'"
    case .unknownDependency(let app, let dependency):
      "application '\(app)' depends on unknown application '\(dependency)'"
    case .dependencyCycle: "application dependencies contain a cycle"
    }
  }
}
