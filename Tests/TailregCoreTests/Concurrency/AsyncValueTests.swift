import Testing

@testable import TailregCore

@Suite(.timeLimit(.minutes(1)))
struct `Async value tests` {
  @Test
  func `A waiter that arrived first is resumed by the fulfilment`() async throws {
    let value = AsyncValue<Int>()
    let waiter = Task { await value.value }
    // Long enough for the waiter to have parked, so this fulfils an outstanding wait rather
    // than racing the task that is meant to be waiting.
    try await Task.sleep(for: .milliseconds(50))

    value.fulfill(7)

    #expect(await waiter.value == 7)
  }

  @Test
  func `A waiter that arrives after the fulfilment does not wait at all`() async {
    let value = AsyncValue<Int>()
    value.fulfill(7)

    #expect(value.isFulfilled)
    #expect(await value.value == 7)
  }

  /// The exits this publishes are reported by a termination handler that can fire more than
  /// once for a process that was signalled twice, and the first report is the true one.
  @Test
  func `A second fulfilment is ignored`() async {
    let value = AsyncValue<Int>()

    value.fulfill(7)
    value.fulfill(9)

    #expect(await value.value == 7)
  }

  @Test
  func `Every waiter is resumed with the same value`() async throws {
    let value = AsyncValue<Int>()
    let waiters = (0..<3).map { _ in Task { await value.value } }
    try await Task.sleep(for: .milliseconds(50))

    value.fulfill(7)

    var resumed: [Int] = []
    for waiter in waiters { resumed.append(await waiter.value) }
    #expect(resumed == [7, 7, 7])
  }
}
