import Foundation
import TailregCore

final class StubProcessRunner: ProcessRunner, @unchecked Sendable {
  struct Invocation: Equatable {
    let executable: String
    let arguments: [String]
  }

  private struct Response {
    let prefix: [String]
    let results: [ProcessResult]
    var callCount = 0
  }

  private let lock = NSLock()
  private var responses: [Response] = []
  private var recorded: [Invocation] = []
  private var launchFailure: String?

  var invocations: [Invocation] { lock.withLock { recorded } }
  var argvHistory: [[String]] { invocations.map(\.arguments) }

  func argv(startingWith prefix: [String]) -> [[String]] {
    argvHistory.filter { $0.starts(with: prefix) }
  }

  func stub(_ prefix: [String], stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
    stub(prefix, results: [Self.result(stdout, stderr, exitCode)])
  }

  func stub(_ prefix: [String], stdoutSequence: [String]) {
    stub(prefix, results: stdoutSequence.map { Self.result($0, "", 0) })
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
      recorded.append(Invocation(executable: executable, arguments: arguments))

      if let launchFailure {
        return .failure(
          ProcessRunnerError.launchFailed(executable: executable, message: launchFailure)
        )
      }
      guard let index = responses.firstIndex(where: { arguments.starts(with: $0.prefix) }) else {
        return .success(ProcessResult(exitCode: 0, standardOutput: Data(), standardError: Data()))
      }
      let response = responses[index]
      responses[index].callCount += 1
      return .success(response.results[min(response.callCount, response.results.count - 1)])
    }
    return try outcome.get()
  }

  private func stub(_ prefix: [String], results: [ProcessResult]) {
    lock.withLock { responses.append(Response(prefix: prefix, results: results)) }
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
