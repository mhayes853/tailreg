import Foundation
import TailregCore
import Testing

@testable import TailregCLI

@Suite(.timeLimit(.minutes(1)))
struct `Supervised command tests` {
  /// Regression coverage for applications inheriting a blocked signal mask through `_exec`.
  ///
  /// `execvp` preserves the caller's blocked mask, and Tailreg spawns from a Swift runtime thread
  /// that blocks almost everything. An application that never receives SIGTERM still disappears,
  /// but only once the supervisor escalates to SIGKILL, so asserting that the process is gone is
  /// not enough: the deadline is what distinguishes a graceful stop from a forced one.
  @Test
  func `Applications launched through the supervisor stop on SIGTERM`() async throws {
    let process = try SystemProcessLauncher()
      .launch(
        ProcessCommand(
          executable: tailregExecutable().path,
          arguments: [SupervisedCommand.marker, "/bin/sleep", "60"]
        )
      )

    try await waitUntilRunning(process.pid)

    let clock = ContinuousClock()
    let start = clock.now
    process.terminateProcessGroup()
    let exit = await process.waitForExit()
    let elapsed = clock.now - start

    #expect(exit.wasTerminatedBySignal)
    #expect(exit.code == SIGTERM)
    #expect(elapsed < .seconds(2))
  }

  #if os(Linux)
    @Test
    func `Applications do not inherit the supervisor's blocked signal mask`() async throws {
      let process = try SystemProcessLauncher()
        .launch(
          ProcessCommand(
            executable: tailregExecutable().path,
            arguments: [
              SupervisedCommand.marker, "/bin/sh", "-c", "grep '^SigBlk' /proc/self/status"
            ]
          )
        )

      var reported: String?
      for await line in process.standardOutput where line.message.hasPrefix("SigBlk") {
        reported = line.message
        break
      }
      _ = await process.waitForExit()

      let mask = try #require(reported?.split(separator: "\t").last.map(String.init))
      #expect(UInt64(mask, radix: 16) == 0)
    }
  #endif

  private func tailregExecutable() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0])
      .deletingLastPathComponent()
      .appendingPathComponent("tailreg")
  }

  /// `execvp` has not necessarily replaced the helper yet, and signalling before it does would
  /// test the helper's own signal state rather than the application's.
  private func waitUntilRunning(_ pid: Int32) async throws {
    for _ in 0..<100 where !isRunning(pid) {
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func isRunning(_ pid: Int32) -> Bool {
    #if os(Linux)
      guard
        let status = try? String(
          contentsOfFile: "/proc/\(pid)/stat",
          encoding: .utf8
        )
      else { return false }
      return status.contains("(sleep)")
    #else
      return processIsAlive(pid)
    #endif
  }
}
