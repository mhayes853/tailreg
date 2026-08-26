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

    do {
      try process.run()
    } catch {
      throw ProcessRunnerError.launchFailed(
        executable: executable,
        message: String(describing: error)
      )
    }

    async let standardOutput = Self.readToEnd(standardOutputPipe.fileHandleForReading)
    async let standardError = Self.readToEnd(standardErrorPipe.fileHandleForReading)
    let (collectedOutput, collectedError) = await (standardOutput, standardError)

    return ProcessResult(
      exitCode: await Self.waitForExit(process),
      standardOutput: collectedOutput,
      standardError: collectedError
    )
  }

  // Draining stdout and stderr concurrently requires two blocking reads to make
  // progress at the same time, or a full pipe buffer on one stream can stall the
  // child indefinitely while the other stream is being read. A shared, bounded
  // DispatchQueue can't guarantee that: on a machine with very few cores its
  // worker pool is small enough to contend with Swift's own concurrency
  // executor, so give each blocking call its own dedicated OS thread instead.
  private static func readToEnd(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        let data = (try? handle.readToEnd()) ?? Data()
        try? handle.close()
        continuation.resume(returning: data)
      }
    }
  }

  private static func waitForExit(_ process: Process) async -> Int32 {
    await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        process.waitUntilExit()
        continuation.resume(returning: process.terminationStatus)
      }
    }
  }
}
