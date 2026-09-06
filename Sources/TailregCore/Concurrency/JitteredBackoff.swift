import Operation

extension OperationBackoffFunction {
  /// This backoff function with jitter applied, for backoffs shorter than a second.
  ///
  /// `OperationBackoffFunction.jittered()` draws the seconds component of its result from
  /// `Int64.random(in: 0..<0)` whenever the backoff is under a second, which traps rather than
  /// returning a sub-second duration. Every backoff here is decided in milliseconds, so none of
  /// them can use it.
  ///
  /// Jitter matters wherever the racers are symmetric: two processes that collide once have
  /// computed the same delay from the same attempt number, and an unjittered backoff schedules
  /// them to collide again.
  public func jitteredBelowOneSecond() -> Self {
    Self("\(self.rawDescription) with sub-second jitter") { attempt in
      let (seconds, attoseconds) = self(attempt).components
      let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
      guard nanoseconds > 0 else { return .zero }
      return .nanoseconds(Int64.random(in: 0..<nanoseconds))
    }
  }
}
