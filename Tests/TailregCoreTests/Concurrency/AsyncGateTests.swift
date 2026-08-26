import Foundation
import TailregCore
import Testing

private actor GatedCounter {
  private let gate = AsyncGate()
  private var active = 0

  private(set) var peakConcurrency = 0
  private(set) var completions: [Int] = []

  func work(_ id: Int, yields: Int = 3) async {
    await gate.withGate {
      active += 1
      peakConcurrency = max(peakConcurrency, active)
      for _ in 0..<yields {
        await Task.yield()
      }
      active -= 1
      completions.append(id)
    }
  }

  func failingWork() async throws {
    try await gate.withGate {
      await Task.yield()
      throw CancellationError()
    }
  }

  func value(_ id: Int) async -> Int {
    await gate.withGate {
      await Task.yield()
      return id * 2
    }
  }
}

private actor UngatedCounter {
  private var active = 0
  private(set) var peakConcurrency = 0

  func work() async {
    active += 1
    peakConcurrency = max(peakConcurrency, active)
    for _ in 0..<3 {
      await Task.yield()
    }
    active -= 1
  }
}

@Suite
struct `AsyncGate tests` {
  @Test
  func `Prevents Two Tasks From Occupying The Critical Section At Once`() async {
    let counter = GatedCounter()

    await withTaskGroup(of: Void.self) { group in
      for id in 0..<8 {
        group.addTask { await counter.work(id) }
      }
    }

    #expect(await counter.peakConcurrency == 1)
    #expect(await counter.completions.count == 8)
  }

  @Test
  func `An Ungated Actor Interleaves Across Suspension Points`() async {
    let counter = UngatedCounter()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask { await counter.work() }
      }
    }

    #expect(await counter.peakConcurrency > 1)
  }

  @Test
  func `Reopens The Gate When The Critical Section Throws`() async throws {
    let counter = GatedCounter()

    await #expect(throws: CancellationError.self) {
      try await counter.failingWork()
    }

    await counter.work(1)
    #expect(await counter.completions == [1])
  }

  @Test
  func `Returns The Value Produced By The Critical Section`() async {
    let counter = GatedCounter()

    #expect(await counter.value(21) == 42)
  }

  @Test
  func `Admits Waiters In The Order They Arrived`() async {
    let counter = GatedCounter()

    let first = Task { await counter.work(0) }
    await Task.yield()
    let second = Task { await counter.work(1) }
    await Task.yield()
    let third = Task { await counter.work(2) }

    _ = await (first.value, second.value, third.value)

    #expect(await counter.completions == [0, 1, 2])
  }

  @Test
  func `Can Be Reacquired Sequentially`() async {
    let counter = GatedCounter()

    for id in 0..<3 {
      await counter.work(id)
    }

    #expect(await counter.completions == [0, 1, 2])
    #expect(await counter.peakConcurrency == 1)
  }
}
