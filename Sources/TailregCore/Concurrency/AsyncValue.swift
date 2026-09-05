import Synchronization

/// A value that is set once and awaited by any number of tasks, before or after it arrives.
///
/// Waiters that arrive after the value has been published resume immediately, so a caller never
/// has to start awaiting before the value can be produced.
public final class AsyncValue<Value: Sendable>: Sendable {
  private struct Storage: Sendable {
    var value: Value?
    var waiters: [CheckedContinuation<Value, Never>] = []
  }

  private let storage = Mutex(Storage())

  public init() {}

  public var isFulfilled: Bool { storage.withLock { $0.value != nil } }

  /// Publishes the value. Later calls are ignored.
  public func fulfill(_ value: Value) {
    let waiters = storage.withLock { storage -> [CheckedContinuation<Value, Never>] in
      guard storage.value == nil else { return [] }
      storage.value = value
      defer { storage.waiters.removeAll() }
      return storage.waiters
    }
    for waiter in waiters {
      waiter.resume(returning: value)
    }
  }

  public var value: Value {
    get async {
      await withCheckedContinuation { continuation in
        storage.withLock { storage in
          if let value = storage.value {
            continuation.resume(returning: value)
          } else {
            storage.waiters.append(continuation)
          }
        }
      }
    }
  }
}
