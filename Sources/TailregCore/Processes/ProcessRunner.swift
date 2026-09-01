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

  private static func readToEnd(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
      processIOQueue.async {
        let data = (try? handle.readToEnd()) ?? Data()
        try? handle.close()
        continuation.resume(returning: data)
      }
    }
  }

  private static func waitForExit(_ process: Process) async -> Int32 {
    await withCheckedContinuation { continuation in
      processIOQueue.async {
        process.waitUntilExit()
        continuation.resume(returning: process.terminationStatus)
      }
    }
  }
}
