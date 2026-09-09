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

    let value = try await poll($isReady(counter), within: .seconds(30), clock: clock)

    #expect(value == 42)
    #expect(counter.count == 1)
    #expect(clock.elapsed == .zero)
  }

  @Test
  func `Returns Nil Once The Budget Elapses`() async throws {
    let clock = ManualClock()
    let counter = AttemptCounter()

    let value: Int? = try await poll(
      $isNeverReady(counter),
      within: .milliseconds(100),
      every: .constant(.milliseconds(25)),
      delayedBy: .clock(clock),
      clock: clock
    )

    #expect(value == nil)
    #expect(counter.count == 5)
  }

  @Test
  func `Attempts Once Even When There Is No Budget To Wait In`() async throws {
    let counter = AttemptCounter()

    let value: Int? = try await poll(
      $isNeverReady(counter),
      within: .zero,
      delayedBy: .noDelay
    )

    #expect(value == nil)
    #expect(counter.count == 1)
  }

  @Test
  func `Lands Its Last Attempt On The Deadline Rather Than Past It`() async throws {
    let clock = ManualClock()
    let counter = AttemptCounter()

    let value: Int? = try await poll(
      $isNeverReady(counter),
      within: .milliseconds(100),
      every: .constant(.seconds(30)),
      delayedBy: .clock(clock),
      clock: clock
    )

    #expect(value == nil)
    #expect(counter.count == 2)
    #expect(clock.elapsed == .milliseconds(100))
  }

  @Test
  func `Rethrows Without Waiting Out The Remaining Budget`() async throws {
    let counter = AttemptCounter()

    await #expect(throws: AttemptFailure(attempt: 3)) {
      try await poll($failsOnAttempt(counter, 3), within: .seconds(30), delayedBy: .noDelay)
    }

    #expect(counter.count == 3)
  }

  @Test
  func `Stops Attempting As Soon As The Awaited State Arrives`() async throws {
    let counter = AttemptCounter()

    let value = try await poll(
      $isReadyOnAttempt(counter, 3),
      within: .seconds(30),
      delayedBy: .noDelay
    )

    #expect(value == "ready")
    #expect(counter.count == 3)
  }

  @Test
  func `Runs Every Attempt Through The Operation Transforms In Scope`() async throws {
    let attempts = AttemptCounter()
    let transformed = AttemptCounter()

    let value = try await withOperationTransform(CountingTransform(counter: transformed)) {
      try await poll(
        $isReadyOnAttempt(attempts, 3),
        within: .seconds(30),
        delayedBy: .noDelay
      )
    }

    #expect(value == "ready")
    #expect(attempts.count == 3)
    #expect(transformed.count == 3)
  }
}

// MARK: - Attempts

@OperationRequest
private func isReady(_ counter: AttemptCounter) async throws -> PollAttempt<Int> {
  counter.record()
  return .ready(42)
}

@OperationRequest
private func isNeverReady(_ counter: AttemptCounter) async throws -> PollAttempt<Int> {
  counter.record()
  return .notYet
}

@OperationRequest
private func failsOnAttempt(
  _ counter: AttemptCounter,
  _ attempt: Int
) async throws -> PollAttempt<Int> {
  let recorded = counter.record()
  guard recorded < attempt else { throw AttemptFailure(attempt: recorded) }
  return .notYet
}

@OperationRequest
private func isReadyOnAttempt(
  _ counter: AttemptCounter,
  _ attempt: Int
) async throws -> PollAttempt<String> {
  counter.record() < attempt ? .notYet : .ready("ready")
}

// MARK: - Transform

/// Counts how many operation runs it sees, so that a transform reaching each attempt is
/// observable.
private struct CountingTransform: OperationTransform {
  let counter: AttemptCounter

  func apply<Operation: OperationRequest>(
    to operation: Operation
  ) -> any OperationRequest<Operation.Value, Operation.Failure> {
    operation.modifier(CountingModifier(counter: self.counter))
  }
}

private struct CountingModifier<Operation: OperationRequest>: OperationModifier, Sendable {
  let counter: AttemptCounter

  func run(
    isolation: isolated (any Actor)?,
    in context: OperationContext,
    using operation: Operation,
    with continuation: OperationContinuation<Operation.Value, Operation.Failure>
  ) async throws(Operation.Failure) -> Operation.Value {
    self.counter.record()
    return try await operation.run(isolation: isolation, in: context, with: continuation)
  }
}
