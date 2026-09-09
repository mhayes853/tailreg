import Foundation
import Testing

@testable import TailregCore

@Suite
struct `Recorded process tests` {
  @Test
  func `This process is running because its start time still matches`() throws {
    let recorded = try #require(
      RecordedProcess(observing: ProcessInfo.processInfo.processIdentifier)
    )

    #expect(recorded.startedAt != nil)
    #expect(recorded.liveness == .running)
  }

  @Test
  func `A different start time on this PID proves the recorded process is gone`() throws {
    let pid = ProcessInfo.processInfo.processIdentifier
    let startedAt = try #require(processStartTime(of: pid))
    let recorded = try #require(RecordedProcess(pid: pid, startedAt: startedAt - 1))

    #expect(recorded.liveness == .gone)
  }

  @Test
  func `A PID no process holds is gone rather than merely unreachable`() throws {
    let recorded = try #require(RecordedProcess(pid: 0x7FFF_FFFE, startedAt: 1))

    #expect(recorded.liveness == .gone)
  }

  /// Absence of evidence is not a fault: without a start time the identity can be neither
  /// confirmed nor disproved, and the callers that reclaim records leave these alone.
  @Test
  func `A process recorded without a start time can never be disproved`() throws {
    let pid = ProcessInfo.processInfo.processIdentifier
    let recorded = try #require(RecordedProcess(pid: pid, startedAt: nil))

    #expect(recorded.liveness == .unverifiable)
  }

  @Test
  func `A PID that cannot name a process is not recorded at all`() {
    #expect(RecordedProcess(pid: 0, startedAt: 1) == nil)
    #expect(RecordedProcess(pid: -1, startedAt: 1) == nil)
    #expect(RecordedProcess(observing: 0) == nil)
  }
}
