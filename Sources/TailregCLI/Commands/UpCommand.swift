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
  var route: String?

  @Option(name: .long, help: "Expected local listener port.")
  var port: PortNumber?

  @Option(name: .long, help: "Attach a loopback URL instead of launching a command.")
  var attach: String?

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

  func makeRequest() throws -> UpRequest {
    if localOnly, tailnetPort != nil {
      throw ValidationError("--tailnet-port has no effect with --local-only")
    }
    if app == nil {
      guard attach == nil, route == nil, port == nil else {
        throw ValidationError("--attach, --route, and --port require --app")
      }
      return UpRequest(
        projectPath: project,
        applicationNames: arguments,
        tailnetPort: tailnetPort,
        localOnly: localOnly
      )
    }

    let attachURL = attach.flatMap(URL.init(string:))
    if attach != nil, attachURL == nil { throw ValidationError("--attach is not a valid URL") }
    if attachURL != nil, !arguments.isEmpty {
      throw ValidationError("an attached application cannot also have a command")
    }
    if attachURL == nil, arguments.isEmpty {
      throw ValidationError("an ad hoc application requires --attach or a command after --")
    }
    return UpRequest(
      projectPath: project,
      adHocApplication: app,
      route: route,
      port: port,
      attachURL: attachURL,
      command: arguments,
      tailnetPort: tailnetPort,
      localOnly: localOnly
    )
  }
}

private enum BackgroundLauncher {
  static func launch(
    databasePath: String,
    environment: [String: String]
  ) async throws {
    let startupTimeout = try MillisecondsSetting.backgroundStartup.resolve(from: environment)
    let directory = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let token = UUID().uuidString.lowercased()
    let readyURL = directory.appendingPathComponent("background-\(token).ready")
    let logURL = directory.appendingPathComponent("background-\(token).log")
    _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = Array(CommandLine.arguments.dropFirst())
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = log
    process.standardError = log
    process.environment = environment.merging([
      "TAILREG_BACKGROUND_CHILD": "1",
      "TAILREG_READY_FILE": readyURL.path
    ]) { _, child in child }
    try withDefaultSignalMaskForSpawn { try process.run() }
    try? log.close()

    defer { try? FileManager.default.removeItem(at: readyURL) }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: startupTimeout)
    while clock.now < deadline {
      if FileManager.default.fileExists(atPath: readyURL.path) {
        let ready = (try? String(contentsOf: readyURL, encoding: .utf8)) ?? ""
        let message =
          "Tailreg started in the background (pid \(process.processIdentifier))."
          + (ready.isEmpty ? "\n" : "\n\(ready)\n")
        try FileHandle.standardOutput.write(contentsOf: Data(message.utf8))
        return
      }
      if !process.isRunning {
        throw BackgroundLaunchError.exited(
          status: process.terminationStatus,
          logPath: logURL.path
        )
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    if process.isRunning { process.terminate() }
    throw BackgroundLaunchError.timedOut(logPath: logURL.path)
  }
}

extension MillisecondsSetting {
  /// How long `up --bg` waits for the background process to report that it is ready.
  static let backgroundStartup = MillisecondsSetting(
    environmentKey: "TAILREG_BACKGROUND_STARTUP_TIMEOUT_MS",
    defaultValue: .seconds(60)
  )

  /// How long `up` waits for an application to listen on its port.
  static let applicationStartup = MillisecondsSetting(
    environmentKey: "TAILREG_STARTUP_TIMEOUT_MS",
    defaultValue: .seconds(30)
  )
}

enum BackgroundLaunchError: Error, CustomStringConvertible, Equatable {
  case exited(status: Int32, logPath: String)
  case timedOut(logPath: String)

  var description: String {
    switch self {
    case .exited(let status, let path):
      "background Tailreg process exited with status \(status); see \(path)"
    case .timedOut(let path): "timed out waiting for background startup; see \(path)"
    }
  }
}
