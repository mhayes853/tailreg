import Foundation
import TailregCore

final class StubProcessRunner: ProcessRunner, @unchecked Sendable {
  private struct Response {
    let prefix: [String]
    let result: ProcessResult
  }

  private let lock = NSLock()
  private var responses: [Response] = []
  private var launchFailure: String?

  func stub(_ prefix: [String], stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
    lock.withLock {
      responses.append(Response(prefix: prefix, result: Self.result(stdout, stderr, exitCode)))
    }
  }

  func failToLaunch(message: String = "no such file") {
    lock.withLock { launchFailure = message }
  }

  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?,
    workingDirectory: String?
  ) async throws -> ProcessResult {
    let outcome: Result<ProcessResult, any Error> = lock.withLock {
      if let launchFailure {
        return .failure(
          ProcessRunnerError.launchFailed(executable: executable, message: launchFailure)
        )
      }
      guard let response = responses.first(where: { arguments.starts(with: $0.prefix) }) else {
        return .success(ProcessResult(exitCode: 0, standardOutput: Data(), standardError: Data()))
      }
      return .success(response.result)
    }
    return try outcome.get()
  }

  private static func result(
    _ stdout: String,
    _ stderr: String,
    _ exitCode: Int32
  ) -> ProcessResult {
    ProcessResult(
      exitCode: exitCode,
      standardOutput: Data(stdout.utf8),
      standardError: Data(stderr.utf8)
    )
  }
}
