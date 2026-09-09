import ArgumentParser
import Foundation
import TailregCore

public struct UpCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "up",
    abstract: "Bring applications up under the current project's MUX."
  )

  @Flag(name: .long, help: "Keep the selected applications running in the background.")
  var bg = false

  @Option(name: .long, help: "Project directory or tailreg.toml path.")
  var project: String?

  @Option(name: .long, help: "Name for one ad hoc application.")
  var app: String?

  @Option(name: .long, help: "Stable MUX route for an ad hoc application.")
  var route: MuxRouteName?

  @Option(name: .long, help: "Expected local listener port.")
  var port: PortNumber?

  @Option(name: .long, help: "Attach a loopback URL instead of launching a command.")
  var attach: LoopbackURL?

  @Option(name: .long, help: "Explicit project Tailscale HTTPS port.")
  var tailnetPort: PortNumber?

  @Flag(name: .long, help: "Expose only on the local MUX listener; do not change Tailscale.")
  var localOnly = false

  @Argument(
    help: "Configured application names, or an ad hoc command after -- when --app is present."
  )
  var arguments: [String] = []

  public init() {}

  public mutating func run() async throws {
    let environment = ProcessInfo.processInfo.environment
    let request = try makeRequest()
    let databasePath = environment.tailregDatabasePath
    if bg && environment["TAILREG_BACKGROUND_CHILD"] != "1" {
      try await BackgroundLauncher.launch(
        databasePath: databasePath,
        environment: environment
      )
      return
    }

    let coordinator = UpCoordinator(
      databasePath: databasePath,
      environment: environment
    )
    _ = try await coordinator.run(request) { result in
      guard let readyPath = environment["TAILREG_READY_FILE"] else { return }
      let lines =
        [result.baseURL.absoluteString]
        + result.applications.compactMap { application in
          application.publicURL.map { "\(application.name)\t\($0.absoluteString)" }
        }
      try? Data(lines.joined(separator: "\n").utf8)
        .write(to: URL(fileURLWithPath: readyPath), options: .atomic)
    }
  }

  /// Resolves the flags into the one selection this invocation describes.
  ///
  /// Every combination refused here is one that would otherwise be obeyed in part: `--port` with
  /// `--attach` would have `up` wait for readiness on a port unrelated to the route it publishes,
  /// and `--tailnet-port` with `--local-only` would name a tailnet port nothing ever binds.
  func makeRequest() throws -> UpRequest {
    if localOnly, tailnetPort != nil {
      throw ValidationError("--tailnet-port has no effect with --local-only")
    }
    guard let app else {
      guard attach == nil, route == nil, port == nil else {
        throw ValidationError("--attach, --route, and --port require --app")
      }
      return UpRequest(
        projectPath: project,
        selection: .configured(arguments),
        tailnetPort: tailnetPort,
        localOnly: localOnly
      )
    }

    let source: UpRequest.AdHocSource
    if let attach {
      guard arguments.isEmpty else {
        throw ValidationError("an attached application cannot also have a command")
      }
      guard port == nil else { throw ValidationError("--port has no effect with --attach") }
      source = .attached(attach)
    } else {
      guard !arguments.isEmpty else {
        throw ValidationError("an ad hoc application requires --attach or a command after --")
      }
      source = .command(arguments, port: port)
    }
    return UpRequest(
      projectPath: project,
      selection: .adHoc(name: app, route: route, source: source),
      tailnetPort: tailnetPort,
      localOnly: localOnly
    )
  }
}
