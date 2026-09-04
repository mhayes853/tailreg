import Foundation
import Synchronization

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
public final class LaunchedProcess: Sendable {
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

  /// Whether the child has exited *and* been reaped.
  ///
  /// This is set by the launcher's own waiter, so it never reports a zombie as running the way a
  /// `kill(pid, 0)` probe would. Callers polling for an owned child's exit should prefer it.
  public var hasExited: Bool { state.hasExited }

  /// Forcefully stops the direct child process.
  ///
  /// This intentionally does not attempt to signal a process tree. Process-group supervision is
  /// a higher-level policy and is not implied by this generic launcher.
  public func terminate() {
    state.forceTerminate(pid: pid)
  }

  /// Requests termination of a process group whose leader is this child.
  ///
  /// The caller is responsible for launching the child as a process-group leader. This is kept
  /// separate from `terminate()` so generic process launches never signal unrelated descendants.
  public func terminateProcessGroup() {
    state.signalProcessGroup(pid: pid, signal: SIGTERM)
  }

  /// Forcefully stops a process group whose leader is this child.
  public func forceTerminateProcessGroup() {
    state.signalProcessGroup(pid: pid, signal: SIGKILL)
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
    if !command.environment.isEmpty {
      process.environment = ProcessInfo.processInfo.environment.merging(command.environment) {
        _,
        configured in
        configured
      }
    }

    let state = ProcessLaunchState()
    // Installed before the launch: a short-lived child can be reaped before `run()` returns, and
    // a handler set afterwards would never be called. Clearing it inside breaks the reference
    // cycle that keeps the `Process` alive until the child is gone.
    process.terminationHandler = { finished in
      finished.terminationHandler = nil
      state.complete(
        with: ProcessExit(
          code: finished.terminationStatus,
          wasTerminatedBySignal: finished.terminationReason == .uncaughtSignal
        )
      )
    }

    do {
      try withDefaultSignalMaskForSpawn { try process.run() }
    } catch {
      process.terminationHandler = nil
      try? standardOutput.fileHandleForReading.close()
      try? standardError.fileHandleForReading.close()
      throw ProcessLaunchError.launchFailed(
        executable: command.executable,
        message: String(describing: error)
      )
    }

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

private final class ProcessLaunchState: Sendable {
  private struct Storage: Sendable {
    var exit: ProcessExit?
    var waiters: [CheckedContinuation<ProcessExit, Never>] = []
  }

  private let storage = Mutex(Storage())

  var hasExited: Bool { storage.withLock { $0.exit != nil } }

  func waitForExit() async -> ProcessExit {
    await withCheckedContinuation { continuation in
      storage.withLock { storage in
        if let exit = storage.exit {
          continuation.resume(returning: exit)
        } else {
          storage.waiters.append(continuation)
        }
      }
    }
  }

  /// Publishes the exit that `Process` reported once it had reaped the child.
  ///
  /// Deliberately not `waitUntilExit()`: on Linux that spins the calling thread's run loop, and a
  /// run loop with no sources returns immediately, so waiting for a child burns a whole core for
  /// as long as the child lives. A handful of concurrent children is enough to starve the
  /// cooperative pool and stall every unrelated task in the process.
  func complete(with exit: ProcessExit) {
    let waiters = storage.withLock { storage -> [CheckedContinuation<ProcessExit, Never>] in
      guard storage.exit == nil else { return [] }
      storage.exit = exit
      defer { storage.waiters.removeAll() }
      return storage.waiters
    }
    for waiter in waiters {
      waiter.resume(returning: exit)
    }
  }

  func forceTerminate(pid: Int32) {
    let exited = storage.withLock { $0.exit != nil }
    if !exited {
      _ = kill(pid, SIGKILL)
    }
  }

  func signalProcessGroup(pid: Int32, signal: Int32) {
    let exited = storage.withLock { $0.exit != nil }
    if !exited {
      _ = kill(-pid, signal)
    }
  }
}
