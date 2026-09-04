import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// The identifier of a process group whose leader's PID is the group's ID.
///
/// Signalling a group is spelled `kill(-id, …)`, which only means "the group" when the value is a
/// group leader's PID. Wrapping it keeps a plain child PID from being passed where a group is
/// required, which would silently signal either nothing or an unrelated group.
public struct ProcessGroupID: Hashable, Sendable, CustomStringConvertible {
  public let rawValue: pid_t

  public init?(_ value: some BinaryInteger) {
    let identifier = pid_t(truncatingIfNeeded: value)
    guard identifier > 0 else { return nil }
    self.rawValue = identifier
  }

  public var description: String { String(rawValue) }
}

public enum TerminationTarget: Hashable, Sendable {
  /// One process. Used for children that are not group leaders.
  case process(pid_t)
  /// Every process in a group, so an application's own children stop with it.
  case processGroup(ProcessGroupID)

  private var signalTarget: pid_t {
    switch self {
    case .process(let pid): pid
    case .processGroup(let group): -group.rawValue
    }
  }

  func send(_ signal: Int32) {
    _ = kill(signalTarget, signal)
  }

  /// Whether signalling this target would still reach something.
  ///
  /// `EPERM` counts as running: the target exists but belongs to another user.
  var isRunning: Bool { signalReaches(signalTarget) }
}

/// How a caller learns that the target stopped.
///
/// The distinction is ownership, not preference. A parent has authoritative, already-reaped exit
/// state; anyone else can only probe with a signal, and a probe cannot distinguish a running
/// process from one that has exited but not yet been reaped.
public enum ProcessExitObservation: Sendable {
  case owned(LaunchedProcess)
  case observed(pollInterval: Duration)

  public static var observed: Self { .observed(pollInterval: .milliseconds(25)) }

  var pollInterval: Duration {
    switch self {
    case .owned: .milliseconds(10)
    case .observed(let interval): interval
    }
  }
}

public enum TerminationOutcome: Hashable, Sendable, CustomStringConvertible {
  case alreadyExited
  case exitedOnTermination(after: Duration)
  case forced(after: Duration)
  /// Escalation did not work: the target was still there after SIGKILL. Almost always a process
  /// blocked in an uninterruptible wait, and the one outcome that means it is still running.
  case unresponsive(after: Duration)

  /// Whether the target ended up stopped, however it got there.
  public var isStopped: Bool {
    if case .unresponsive = self { return false }
    return true
  }

  public var description: String {
    switch self {
    case .alreadyExited: "already stopped"
    case .exitedOnTermination: "stopped"
    case .forced(let elapsed): "did not stop within \(elapsed); killed"
    case .unresponsive(let elapsed): "did not stop within \(elapsed), and survived being killed"
    }
  }
}

/// Stops a process or process group gracefully, escalating only when it has to.
///
/// One escalation policy for every process Tailreg owns. Escalation is always conditional on the
/// target still running, so a stopped process is never signalled again after its PID may have been
/// recycled.
public struct ProcessTerminator<C: Clock>: Sendable where C.Instant.Duration == Duration {
  /// How long to confirm a SIGKILL landed. Reaching this means the target is unkillable, which is
  /// reported rather than waited out.
  private static var forcedConfirmation: Duration { .seconds(1) }

  private let grace: Duration
  private let clock: C

  /// - Parameter grace: How long the target has to stop after SIGTERM before it is killed.
  public init(
    grace: Duration = MillisecondsSetting.terminationGrace.defaultValue,
    clock: C = ContinuousClock()
  ) {
    self.grace = grace
    self.clock = clock
  }

  /// A terminator whose grace period comes from the environment.
  public init(environment: [String: String]) throws where C == ContinuousClock {
    self.init(grace: try MillisecondsSetting.terminationGrace.resolve(from: environment))
  }

  /// Asks the target to stop, without waiting for it.
  ///
  /// Signal handlers and cancellation callbacks are synchronous and cannot await the full policy,
  /// but a Ctrl-C must not be lost while a task is scheduled. Those contexts request the stop
  /// inline and leave the waiting and escalation to `terminate`, so the escalation decision is
  /// still made in exactly one place. Calling both is safe: a repeated SIGTERM is idempotent.
  public func requestStop(_ target: TerminationTarget) {
    guard target.isRunning else { return }
    target.send(SIGTERM)
  }

  public func terminate(
    _ target: TerminationTarget,
    observing observation: ProcessExitObservation
  ) async -> TerminationOutcome {
    guard !hasExited(target, observing: observation) else { return .alreadyExited }

    let start = clock.now
    target.send(SIGTERM)
    if await waitForExit(target, observing: observation, within: grace) {
      return .exitedOnTermination(after: start.duration(to: clock.now))
    }

    target.send(SIGKILL)
    let stopped = await waitForExit(
      target,
      observing: observation,
      within: Self.forcedConfirmation
    )
    let elapsed = start.duration(to: clock.now)
    return stopped ? .forced(after: elapsed) : .unresponsive(after: elapsed)
  }

  /// Stops the process group led by a child this process launched and still owns.
  @discardableResult
  public func stopProcessGroup(of process: LaunchedProcess) async -> TerminationOutcome {
    guard let group = ProcessGroupID(process.pid) else { return .alreadyExited }
    return await terminate(.processGroup(group), observing: .owned(process))
  }

  private func waitForExit(
    _ target: TerminationTarget,
    observing observation: ProcessExitObservation,
    within limit: Duration
  ) async -> Bool {
    let deadline = clock.now.advanced(by: limit)
    while clock.now < deadline {
      if hasExited(target, observing: observation) { return true }
      guard (try? await clock.sleep(for: observation.pollInterval)) != nil else { break }
    }
    return hasExited(target, observing: observation)
  }

  private func hasExited(
    _ target: TerminationTarget,
    observing observation: ProcessExitObservation
  ) -> Bool {
    switch observation {
    case .owned(let process): process.hasExited
    case .observed: !target.isRunning
    }
  }
}
