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
    let routes = applications.compactMap(\.route)
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

public struct ApplicationSpecification: Equatable, Sendable {
  public let name: String
  public let route: String?
  public let port: PortNumber?
  public let attachURL: URL?
  public let command: ProcessCommand?
  public let dependencies: [String]
  public let isExposed: Bool
  public let pathMode: MuxRoutePathMode

  public var listenerPort: PortNumber? { port ?? attachURL?.listenerPort }

  var upstreamURL: URL {
    guard let upstream = attachURL ?? port.flatMap({ URL(string: "http://127.0.0.1:\($0)") }) else {
      fatalError("An exposed application must have an upstream after validation")
    }
    return upstream
  }

  public init(
    name: String,
    route: String? = nil,
    port: PortNumber? = nil,
    attachURL: URL? = nil,
    command: ProcessCommand? = nil,
    dependencies: [String] = [],
    isExposed: Bool = true,
    pathMode: MuxRoutePathMode = .stripRoutePrefix
  ) throws {
    self.name = name
    self.route = route
    self.port = port
    self.attachURL = attachURL
    self.command = command
    self.dependencies = dependencies
    self.isExposed = isExposed
    self.pathMode = pathMode
    try validate()
  }

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
    try self.init(
      name: name,
      route: raw.route,
      port: raw.port,
      attachURL: raw.attach.flatMap(URL.init(string:)),
      command: command,
      dependencies: raw.dependsOn ?? [],
      isExposed: raw.expose ?? true,
      pathMode: raw.preserveRoutePrefix == true ? .preserveRoutePrefix : .stripRoutePrefix
    )
    if raw.attach != nil, attachURL == nil {
      throw ProjectSpecificationError.invalidAttachURL(name)
    }
  }

  private func validate() throws {
    guard !name.isEmpty else { throw ProjectSpecificationError.invalidApplicationName }
    guard command != nil || attachURL != nil else {
      throw ProjectSpecificationError.missingCommandOrAttach(name)
    }
    guard command == nil || attachURL == nil else {
      throw ProjectSpecificationError.commandAndAttach(name)
    }
    if let attachURL {
      guard attachURL.scheme == "http" || attachURL.scheme == "https",
        let host = attachURL.host,
        ["127.0.0.1", "localhost", "::1"].contains(host)
      else {
        throw ProjectSpecificationError.invalidAttachURL(name)
      }
    }
    if isExposed, listenerPort == nil {
      throw ProjectSpecificationError.missingPort(name)
    }
    if let route, !MuxRouteName.isValid(route) {
      throw ProjectSpecificationError.invalidRoute(application: name, route: route)
    }
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
    case .invalidRoute(let app, let route): "application '\(app)' has invalid route '\(route)'"
    case .unknownApplication(let app): "unknown application '\(app)'"
    case .unknownDependency(let app, let dependency):
      "application '\(app)' depends on unknown application '\(dependency)'"
    case .dependencyCycle: "application dependencies contain a cycle"
    }
  }
}
