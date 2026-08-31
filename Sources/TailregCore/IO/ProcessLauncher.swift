import Dispatch
import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

public struct ProcessExit: Sendable, Equatable {
  public let code: Int32
  public let wasTerminatedBySignal: Bool

  public init(code: Int32, wasTerminatedBySignal: Bool) {
    self.code = code
    self.wasTerminatedBySignal = wasTerminatedBySignal
  }
}

public enum ProcessLaunchError: Error, Sendable, Equatable {
  case emptyExecutable
  case nulByte
  case executableNotFound(String)
  case launchFailed(executable: String, message: String)
}

public protocol ProcessLaunching: Sendable {
  func launch(_ command: ProcessCommand) throws -> LaunchedProcess
}

/// A process started by a `ProcessLaunching` implementation.
///
/// Output readers are installed before this value is returned, so a caller does not need to start
/// iterating its streams immediately to prevent a child from blocking on a full OS pipe.
public final class LaunchedProcess: @unchecked Sendable {
  public let pid: Int32
  public let standardOutput: AsyncStream<LogLine>
  public let standardError: AsyncStream<LogLine>

  private let state: ProcessLaunchState

  fileprivate init(
    pid: Int32,
    standardOutput: AsyncStream<LogLine>,
    standardError: AsyncStream<LogLine>,
    state: ProcessLaunchState
  ) {
    self.pid = pid
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.state = state
  }

  public func waitForExit() async -> ProcessExit {
    await state.waitForExit()
  }

  /// Forcefully stops the direct child process.
  ///
  /// This intentionally does not attempt to signal a process tree. Process-group supervision is
  /// a higher-level policy and is not implied by this generic launcher.
  public func terminate() {
    state.forceTerminate()
  }
}

public struct SystemProcessLauncher: ProcessLaunching {
  public init() {}

  public func launch(_ command: ProcessCommand) throws -> LaunchedProcess {
    guard !command.executable.isEmpty else { throw ProcessLaunchError.emptyExecutable }
    guard !command.executable.contains("\0"),
      !command.arguments.contains(where: { $0.contains("\0") })
    else {
      throw ProcessLaunchError.nulByte
    }

    let executableURL = try executableURL(for: command)
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let output = processOutputLines(standardOutput.fileHandleForReading, as: .standardOutput)
    let error = processOutputLines(standardError.fileHandleForReading, as: .standardError)

    process.executableURL = executableURL
    process.arguments = command.arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.currentDirectoryURL = command.workingDirectory

    let state = ProcessLaunchState(process: process)

    do {
      try process.run()
    } catch {
      try? standardOutput.fileHandleForReading.close()
      try? standardError.fileHandleForReading.close()
      throw ProcessLaunchError.launchFailed(
        executable: command.executable,
        message: String(describing: error)
      )
    }
    state.beginWaiting()

    return LaunchedProcess(
      pid: process.processIdentifier,
      standardOutput: output,
      standardError: error,
      state: state
    )
  }

  private func executableURL(for command: ProcessCommand) throws -> URL {
    if command.executable.contains("/") {
      return URL(fileURLWithPath: command.executable, relativeTo: command.workingDirectory)
        .standardizedFileURL
    }

    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let workingDirectory =
      command.workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for component in path.split(separator: ":", omittingEmptySubsequences: false) {
      let directory =
        component.isEmpty
        ? workingDirectory
        : URL(fileURLWithPath: String(component), isDirectory: true)
      let candidate = directory.appendingPathComponent(command.executable).path
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return URL(fileURLWithPath: candidate)
      }
    }
    throw ProcessLaunchError.executableNotFound(command.executable)
  }
}

private final class ProcessLaunchState: @unchecked Sendable {
  private let process: Process
  private let lock = NSLock()
  private var exit: ProcessExit?
  private var waiters: [CheckedContinuation<ProcessExit, Never>] = []

  init(process: Process) {
    self.process = process
  }

  func waitForExit() async -> ProcessExit {
    await withCheckedContinuation { continuation in
      lock.withLock {
        if let exit {
          continuation.resume(returning: exit)
        } else {
          waiters.append(continuation)
        }
      }
    }
  }

  func beginWaiting() {
    processLifecycleQueue.async { [self] in
      process.waitUntilExit()
      recordExit(
        ProcessExit(
          code: process.terminationStatus,
          wasTerminatedBySignal: process.terminationReason == .uncaughtSignal
        )
      )
    }
  }

  func recordExit(_ exit: ProcessExit) {
    let waiters = lock.withLock { () -> [CheckedContinuation<ProcessExit, Never>] in
      guard self.exit == nil else { return [] }
      self.exit = exit
      defer { self.waiters.removeAll() }
      return self.waiters
    }
    for waiter in waiters {
      waiter.resume(returning: exit)
    }
  }

  func forceTerminate() {
    lock.withLock {
      guard exit == nil else { return }
      _ = kill(process.processIdentifier, SIGKILL)
    }
  }
}

private let processLifecycleQueue = DispatchQueue(
  label: "com.tailreg.io.process-launcher.lifecycle",
  attributes: .concurrent
)
