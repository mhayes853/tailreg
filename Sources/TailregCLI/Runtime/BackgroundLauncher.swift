import Foundation
import TailregCore

/// Re-executes this invocation with its standard streams redirected to a state-directory log.
///
/// The parent waits for the child to write a readiness file rather than returning as soon as it
/// has forked: `up --bg` that returned before the project was reachable would be indistinguishable
/// from one that failed on its first line, and the URLs it prints are the whole point of running
/// it. A child that exits or never reports is diagnosed against its log.
enum BackgroundLauncher {
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
