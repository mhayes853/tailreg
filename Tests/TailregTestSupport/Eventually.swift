/// Polls `operation` until its result satisfies `until`, then returns it.
///
/// For state that a test can observe but not order: a spawned process appearing in the process
/// table, a batch reaching the database. The final attempt's value is returned either way, so a
/// timed-out poll fails on the assertion the caller actually cares about rather than on a
/// timeout.
public func eventually<Value>(
  _ operation: () async throws -> Value,
  until predicate: (Value) -> Bool,
  attempts: Int = 100,
  interval: Duration = .milliseconds(25)
) async throws -> Value {
  for _ in 0..<max(attempts - 1, 0) {
    let value = try await operation()
    if predicate(value) { return value }
    try await Task.sleep(for: interval)
  }
  return try await operation()
}
