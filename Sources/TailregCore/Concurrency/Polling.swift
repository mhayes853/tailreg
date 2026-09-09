import Operation

/// What one attempt of a poll learned.
public enum PollAttempt<Value: Sendable>: Sendable {
  /// The awaited state has arrived.
  case ready(Value)
  /// Not yet. Another attempt is worth making if there is budget left.
  case notYet
}

/// Runs `operation` until it reports `.ready`, until `limit` elapses, or until it throws.
///
/// Returns `nil` when the budget runs out rather than throwing, so each caller reports the
/// timeout its own command should report: "the application never listened on its port" and
/// "the MUX never answered its admin port" are the same wait but not the same diagnosis.
///
/// An `operation` that throws aborts immediately. Waiting is only worth doing while the awaited
/// state is still possible, and a child that has already exited will never reach it — that is a
/// different answer from "not yet", and it arrives before the deadline rather than at it.
///
/// The budget is spent on attempts, never overshot by a sleep: the final delay is clamped to
/// whatever remains, so the last attempt lands at the deadline instead of past it.
///
/// Each attempt is an operation rather than a closure so that it runs through `OperationRunner`,
/// which is what puts it in reach of any ``OperationTransform`` the caller has in scope.
public func poll<Operation: OperationRequest, Value: Sendable, C: Clock>(
  _ operation: Operation,
  within limit: Duration,
  every backoff: OperationBackoffFunction = .constant(.milliseconds(100)),
  delayedBy delayer: any OperationDelayer & Sendable = .taskSleep,
  clock: C = ContinuousClock(),
  isolation: isolated (any Actor)? = #isolation
) async throws -> Value?
where Operation.Value == PollAttempt<Value>, C.Duration == Duration {
  let runner = OperationRunner(operation: operation)
  let deadline = clock.now.advanced(by: limit)
  var retries = 0
  while true {
    if case .ready(let value) = try await runner.run(isolation: isolation) { return value }
    let remaining = clock.now.duration(to: deadline)
    guard remaining > .zero else { return nil }
    retries += 1
    try await delayer.delay(for: min(Duration(duration: backoff(retries)), remaining))
  }
}
