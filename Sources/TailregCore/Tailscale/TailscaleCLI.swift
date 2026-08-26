import Foundation

public struct TailscaleCLI: Sendable {
  public let binaryPath: String
  private let runner: any ProcessRunner

  public init(binaryPath: String, runner: any ProcessRunner) {
    self.binaryPath = binaryPath
    self.runner = runner
  }

  // MARK: - Reads

  public func version() async throws -> String {
    let result = try await invoke(["version"], allowingFailure: false)
    return result.standardOutputText
      .split(separator: "\n", maxSplits: 1)
      .first
      .map(String.init) ?? ""
  }

  public func status() async throws -> TailscaleStatus {
    let result = try await invoke(["status", "--json"], allowingFailure: true)
    guard !result.standardOutput.isEmpty else {
      throw mapFailure(argv: ["status", "--json"], result: result)
    }
    do {
      return try JSONDecoder().decode(TailscaleStatus.self, from: result.standardOutput)
    } catch {
      guard result.exitCode == 0 else {
        throw mapFailure(argv: ["status", "--json"], result: result)
      }
      throw TailscaleError.malformedOutput(
        command: "status --json",
        detail: String(describing: error)
      )
    }
  }

  public func serveStatus(hostname: String) async throws -> [TailscaleBinding] {
    let result = try await invoke(["serve", "status", "--json"], allowingFailure: false)
    return try TailscaleServeStatus.decode(result.standardOutput, hostname: hostname)
  }

  // MARK: - Mutations

  public func serve(
    localPort: Int,
    tailnetPort: Int,
    proto: TailscaleServeProtocol,
    mountPath: String,
    funnel: Bool
  ) async throws {
    var argv = [funnel ? "funnel" : "serve", "--bg", "--yes", "\(proto.flagName)=\(tailnetPort)"]
    if mountPath != "/" {
      argv.append("--set-path=\(mountPath)")
    }
    argv.append("http://127.0.0.1:\(localPort)")
    _ = try await invoke(argv, allowingFailure: false)
  }

  public func serveOff(
    tailnetPort: Int,
    proto: TailscaleServeProtocol,
    mountPath: String
  ) async throws {
    var argv = ["serve", "\(proto.flagName)=\(tailnetPort)"]
    if mountPath != "/" {
      argv.append("--set-path=\(mountPath)")
    }
    argv.append("off")
    _ = try await invoke(argv, allowingFailure: false)
  }

  // MARK: - Invocation

  private func invoke(_ argv: [String], allowingFailure: Bool) async throws -> ProcessResult {
    let result: ProcessResult
    do {
      result = try await runner.run(executable: binaryPath, arguments: argv)
    } catch {
      throw TailscaleError.notInstalled
    }
    guard allowingFailure || result.exitCode == 0 else {
      throw mapFailure(argv: argv, result: result)
    }
    return result
  }

  private func mapFailure(argv: [String], result: ProcessResult) -> TailscaleError {
    let stderr = result.standardErrorText
    let lowercased = stderr.lowercased()

    if lowercased.contains("operator")
      || lowercased.contains("permission denied")
      || lowercased.contains("access denied")
      || lowercased.contains("must be run as root")
    {
      return .operatorPermissionDenied
    }
    if lowercased.contains("stopped") || lowercased.contains("needslogin")
      || lowercased.contains("logged out") || lowercased.contains("not running")
    {
      return .daemonNotRunning(state: stderr)
    }
    return .commandFailed(argv: argv, exitCode: result.exitCode, standardError: stderr)
  }
}
