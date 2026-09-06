import Operation
import Synchronization
import TailregCore
import Testing

private final class AttemptCounter: Sendable {
  private let state = Mutex(0)

  var count: Int { state.withLock { $0 } }

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

@OperationRequest
private func alwaysFailing(_ counter: AttemptCounter) async throws -> Int {
  throw AttemptFailure(attempt: counter.record())
}

@OperationRequest
private func succeeding(_ counter: AttemptCounter) async throws -> Int {
  counter.record()
}

@Suite
struct `Conditional retry tests` {
  @Test
  func `Runs Once More Than The Limit When Every Failure Is Worth Retrying`() async throws {
    let counter = AttemptCounter()

    await #expect(throws: AttemptFailure(attempt: 4)) {
      try await #run(
        $alwaysFailing(counter)
          .retry(limit: 3) { _ in true }
          .delayer(.noDelay)
      )
    }

    #expect(counter.count == 4)
  }

  @Test
  func `Rethrows The Failure The Predicate Rejected, Not A Later One`() async throws {
    let counter = AttemptCounter()

    await #expect(throws: AttemptFailure(attempt: 2)) {
      try await #run(
        $alwaysFailing(counter)
          .retry(limit: 5) { ($0 as? AttemptFailure)?.attempt != 2 }
          .delayer(.noDelay)
      )
    }

    #expect(counter.count == 2)
  }

  @Test
  func `Does Not Retry A Failure That Is Rejected On The First Attempt`() async throws {
    let counter = AttemptCounter()

    await #expect(throws: AttemptFailure(attempt: 1)) {
      try await #run(
        $alwaysFailing(counter)
          .retry(limit: 5) { _ in false }
          .delayer(.noDelay)
      )
    }

    #expect(counter.count == 1)
  }

  @Test
  func `Runs An Operation That Succeeds Exactly Once`() async throws {
    let counter = AttemptCounter()

    let value = try await #run(
      $succeeding(counter)
        .retry(limit: 3) { _ in true }
        .delayer(.noDelay)
    )

    #expect(value == 1)
    #expect(counter.count == 1)
  }
}
