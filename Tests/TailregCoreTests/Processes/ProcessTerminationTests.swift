import Foundation
import Testing

@testable import TailregCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@Suite(.timeLimit(.minutes(1)))
struct `Process termination tests` {
  @Test
  func `A cooperative process stops on the graceful signal`() async throws {
    let process = try launch("/bin/sleep", "60")
    let terminator = ProcessTerminator()

    let outcome = await terminator.terminate(.process(process.pid), observing: .observed)

    guard case .exitedOnTermination(let elapsed) = outcome else {
      Issue.record("expected a graceful stop, got \(outcome)")
      return
    }
    #expect(elapsed < .seconds(2))
  }

  /// The distinction that matters: a process that never handles SIGTERM still disappears, so an
  /// outcome of "gone" would report success for a policy that silently degraded to SIGKILL.
  @Test
  func `A process ignoring the graceful signal is escalated and reported as forced`() async throws {
    let process = try launch(
      "/bin/sh",
      "-c",
      "trap '' TERM; echo ready; while :; do sleep 0.1; done"
    )
    // Signalling before the shell installs its trap would test the default disposition instead.
    for await line in process.standardOutput where line.message == "ready" { break }
    let grace = try #require(TerminationGracePeriod(rawValue: 300))
    let terminator = ProcessTerminator(grace: grace)

    let outcome = await terminator.terminate(
      .process(process.pid),
      observing: .owned(process)
    )

    guard case .forced(let elapsed) = outcome else {
      Issue.record("expected a forced stop, got \(outcome)")
      return
    }
    #expect(elapsed >= .milliseconds(300))
    #expect(process.hasExited)
  }

  @Test
  func `A process that has already stopped is not signalled again`() async throws {
    let process = try launch("/bin/sh", "-c", "exit 0")
    _ = await process.waitForExit()

    let outcome = await ProcessTerminator()
      .terminate(.process(process.pid), observing: .owned(process))

    #expect(outcome == .alreadyExited)
  }

  @Test
  func `An owned child reports its exit without a liveness probe`() async throws {
    let process = try launch("/bin/sleep", "60")
    let terminator = ProcessTerminator()

    let outcome = await terminator.terminate(.process(process.pid), observing: .owned(process))

    #expect(process.hasExited)
    guard case .exitedOnTermination = outcome else {
      Issue.record("expected a graceful stop, got \(outcome)")
      return
    }
  }

  @Test
  func `Process group identifiers reject values that are not a group`() {
    #expect(ProcessGroupID(0) == nil)
    #expect(ProcessGroupID(-1) == nil)
    #expect(ProcessGroupID(42)?.rawValue == 42)
  }

  @Test
  func `The grace period falls back to its default when unconfigured`() throws {
    #expect(try TerminationGracePeriod(environment: [:]) == .default)
  }

  @Test
  func `The grace period reads a configured millisecond value`() throws {
    let period = try TerminationGracePeriod(
      environment: [TerminationGracePeriod.environmentKey: "1500"]
    )
    #expect(period.duration == .milliseconds(1500))
  }

  @Test(arguments: ["0", "-1", "soon", ""])
  func `The grace period rejects values that are not positive milliseconds`(_ value: String) {
    #expect(throws: TerminationGracePeriodError.invalid(value)) {
      try TerminationGracePeriod(environment: [TerminationGracePeriod.environmentKey: value])
    }
  }

  /// Foundation's `Process` hands the child the spawning thread's signal mask, and Swift
  /// concurrency threads block nearly everything. Applications get a clean slate from the `_exec`
  /// helper, but these tests launch directly, so they clear the mask here in order to exercise
  /// the terminator rather than mask inheritance.
  private func launch(_ executable: String, _ arguments: String...) throws -> LaunchedProcess {
    var empty = sigset_t()
    sigemptyset(&empty)
    pthread_sigmask(SIG_SETMASK, &empty, nil)
    return try SystemProcessLauncher()
      .launch(ProcessCommand(executable: executable, arguments: arguments))
  }
}
