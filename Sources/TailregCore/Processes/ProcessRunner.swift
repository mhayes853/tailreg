import Dispatch
import Foundation
import Synchronization

// MARK: - Result

public struct ProcessResult: Sendable, Equatable {
  public let exitCode: Int32
  public let standardOutput: Data
  public let standardError: Data

  public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
  }

  public var standardOutputText: String {
    String(decoding: standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var standardErrorText: String {
    String(decoding: standardError, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - Errors

public enum ProcessRunnerError: Error, Sendable, Equatable {
  case launchFailed(executable: String, message: String)
}

// MARK: - Protocol

public protocol ProcessRunner: Sendable {
  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?,
    workingDirectory: String?
  ) async throws -> ProcessResult
}

extension ProcessRunner {
  public func run(executable: String, arguments: [String]) async throws -> ProcessResult {
    try await run(
      executable: executable,
      arguments: arguments,
      environment: nil,
      workingDirectory: nil
    )
  }
}

// MARK: - System implementation

private let processIOQueue = DispatchQueue(
  label: "com.tailreg.io.process",
  attributes: .concurrent
)

public struct SystemProcessRunner: ProcessRunner {
  public init() {}

  public func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?,
    workingDirectory: String?
  ) async throws -> ProcessResult {
    let process = Process()
    let standardOutputPipe = Pipe()
    let standardErrorPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = standardOutputPipe
    process.standardError = standardErrorPipe
    process.standardInput = FileHandle.nullDevice
    if let environment {
      process.environment = environment
    }
    if let workingDirectory {
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }

    // Installed before the launch: a child can be reaped before `run()` returns, and a handler
    // set afterwards would never be called.
    let exited = ExitReport()
    process.terminationHandler = { finished in
      finished.terminationHandler = nil
      exited.report(finished.terminationStatus)
    }

    do {
      try withDefaultSignalMaskForSpawn { try process.run() }
    } catch {
      process.terminationHandler = nil
      throw ProcessRunnerError.launchFailed(
        executable: executable,
        message: String(describing: error)
      )
    }

    async let standardOutput = Self.readToEnd(standardOutputPipe.fileHandleForReading)
    async let standardError = Self.readToEnd(standardErrorPipe.fileHandleForReading)
    let (collectedOutput, collectedError) = await (standardOutput, standardError)

    return ProcessResult(
      exitCode: await exited.value,
      standardOutput: collectedOutput,
      standardError: collectedError
    )
  }

  private static func readToEnd(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
      processIOQueue.async {
        let data = (try? handle.readToEnd()) ?? Data()
        try? handle.close()
        continuation.resume(returning: data)
      }
    }
  }

}

/// A child's exit status, published to whoever asks for it whenever it arrives.
///
/// Deliberately not `waitUntilExit()`: on Linux that spins the calling thread's run loop, and a
/// run loop with no sources returns immediately, so waiting for a child burns a whole core for as
/// long as the child lives.
private final class ExitReport: Sendable {
  private struct Storage: Sendable {
    var status: Int32?
    var waiters: [CheckedContinuation<Int32, Never>] = []
  }

  private let storage = Mutex(Storage())

  var value: Int32 {
    get async {
      await withCheckedContinuation { continuation in
        storage.withLock { storage in
          if let status = storage.status {
            continuation.resume(returning: status)
          } else {
            storage.waiters.append(continuation)
          }
        }
      }
    }
  }

  func report(_ status: Int32) {
    let waiters = storage.withLock { storage -> [CheckedContinuation<Int32, Never>] in
      guard storage.status == nil else { return [] }
      storage.status = status
      defer { storage.waiters.removeAll() }
      return storage.waiters
    }
    for waiter in waiters { waiter.resume(returning: status) }
  }
}
