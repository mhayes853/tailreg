import Dispatch
import Foundation

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
    //
    // Deliberately not `waitUntilExit()`: on Linux that spins the calling thread's run loop, and
    // a run loop with no sources returns immediately, so waiting for a child burns a whole core
    // for as long as the child lives.
    let exited = AsyncValue<Int32>()
    process.terminationHandler = { finished in
      exited.fulfill(finished.terminationStatus)
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
