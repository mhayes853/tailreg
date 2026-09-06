import Operation
import Synchronization
import TailregCore
import Testing

/// A clock that only ever moves when something sleeps on it.
///
/// Polling is arithmetic on a budget, and testing it against a real clock either sleeps for the
/// budget or races it. Driving the delays and the deadline from the same manual instant makes the
/// number of attempts a poll gets, and where its last one lands, exactly observable.
private final class ManualClock: Clock, Sendable {
  struct Instant: InstantProtocol {
    let elapsed: Duration

    func advanced(by duration: Duration) -> Self { Self(elapsed: elapsed + duration) }
    func duration(to other: Self) -> Duration { other.elapsed - elapsed }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.elapsed < rhs.elapsed }
  }

  private let state = Mutex(Duration.zero)

  var now: Instant { Instant(elapsed: state.withLock { $0 }) }
  var minimumResolution: Duration { .zero }
  var elapsed: Duration { state.withLock { $0 } }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    state.withLock { $0 = max($0, deadline.elapsed) }
  }
}

private final class AttemptCounter: Sendable {
  private let state = Mutex(0)

  var count: Int { state.withLock { $0 } }

  @discardableResult
  func record() -> Int {
    state.withLock { count in
      count += 1
      return count
    }
  }
}

private struct AttemptFailure: Error, Equatable {
  let attempt: Int
}

@Suite
struct `Polling tests` {
  @Test
  func `Returns The First Attempt's Value Without Delaying`() async throws {
    let clock = ManualClock()
    let counter = AttemptCounter()

    let value = try await poll(within: .seconds(30), clock: clock) {
      counter.record()
      return .ready(42)
    }

    #expect(value == 42)
    #expect(counter.count == 1)
    #expect(clock.elapsed == .zero)
  }

  @Test
  func `Returns Nil Once The Budget Elapses`() async throws {
    let clock = ManualClock()
    let counter = AttemptCounter()

    let value: Int? = try await poll(
      within: .milliseconds(100),
      every: .constant(.milliseconds(25)),
      delayedBy: .clock(clock),
      clock: clock
    ) {
      counter.record()
      return .notYet
    }

    #expect(value == nil)
    #expect(counter.count == 5)
  }

  @Test
  func `Attempts Once Even When There Is No Budget To Wait In`() async throws {
    let counter = AttemptCounter()

    let value: Int? = try await poll(within: .zero, delayedBy: .noDelay) {
      counter.record()
      return .notYet
    }

    #expect(value == nil)
    #expect(counter.count == 1)
  }

  @Test
  func `Lands Its Last Attempt On The Deadline Rather Than Past It`() async throws {
    let clock = ManualClock()
    let counter = AttemptCounter()

    let value: Int? = try await poll(
      within: .milliseconds(100),
      every: .constant(.seconds(30)),
      delayedBy: .clock(clock),
      clock: clock
    ) {
      counter.record()
      return .notYet
    }

    #expect(value == nil)
    #expect(counter.count == 2)
    #expect(clock.elapsed == .milliseconds(100))
  }

  @Test
  func `Rethrows Without Waiting Out The Remaining Budget`() async throws {
    let counter = AttemptCounter()

    await #expect(throws: AttemptFailure(attempt: 3)) {
      try await poll(within: .seconds(30), delayedBy: .noDelay) {
        let attempt = counter.record()
        guard attempt < 3 else { throw AttemptFailure(attempt: attempt) }
        return PollAttempt<Int>.notYet
      }
    }

    #expect(counter.count == 3)
  }

  @Test
  func `Stops Attempting As Soon As The Awaited State Arrives`() async throws {
    let counter = AttemptCounter()

    let value = try await poll(within: .seconds(30), delayedBy: .noDelay) {
      counter.record() < 3 ? .notYet : .ready("ready")
    }

    #expect(value == "ready")
    #expect(counter.count == 3)
  }
}
