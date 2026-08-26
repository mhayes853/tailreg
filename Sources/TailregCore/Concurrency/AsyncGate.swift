import Foundation

public final class AsyncGate {
  private struct Waiter {
    let continuation: CheckedContinuation<Void, Never>
  }

  private enum State {
    case open
    case closed([Waiter])
  }

  private let lock = NSLock()
  private var state: State = .open

  public init() {}

  public func withGate<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ operation: () async throws -> T
  ) async rethrows -> T {
    await close(isolation: isolation)
    defer { open() }
    return try await operation()
  }

  // MARK: - State transitions

  private func close(isolation: isolated (any Actor)?) async {
    await withCheckedContinuation(isolation: isolation) { continuation in
      lock.lock()
      switch state {
      case .open:
        state = .closed([])
        lock.unlock()
        continuation.resume()
      case .closed(let waiters):
        state = .closed(waiters + [Waiter(continuation: continuation)])
        lock.unlock()
      }
    }
  }

  private func open() {
    lock.lock()
    switch state {
    case .open:
      lock.unlock()
    case .closed(var waiters):
      guard !waiters.isEmpty else {
        state = .open
        lock.unlock()
        return
      }
      let next = waiters.removeFirst()
      state = .closed(waiters)
      lock.unlock()
      next.continuation.resume()
    }
  }
}
