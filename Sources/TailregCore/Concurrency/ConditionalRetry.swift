import Operation

extension OperationRequest {
  /// Retries this operation, but only for the failures `isWorthRetrying` accepts.
  ///
  /// ``OperationRequest/retry(limit:)`` treats every failure alike, which is wrong wherever one
  /// error type carries both "the race was lost, try again" and "this cannot work". Those are not
  /// told apart by how many attempts have been made, only by the error itself, and retrying the
  /// second kind turns one clear failure into the same failure reported late.
  ///
  /// A rejected failure is rethrown immediately, so the caller sees the error that actually
  /// stopped the operation rather than whichever one happened to come last.
  ///
  /// - Parameters:
  ///   - limit: The maximum number of retries. Retries follow the initial attempt, so the
  ///     operation runs at most `limit + 1` times.
  ///   - isWorthRetrying: Whether a failure is worth another attempt.
  /// - Returns: A `ModifiedOperation`.
  public func retry(
    limit: Int,
    while isWorthRetrying: @escaping @Sendable (Failure) -> Bool
  ) -> ModifiedOperation<Self, ConditionalRetryModifier<Self>> {
    self.modifier(ConditionalRetryModifier(limit: limit, isWorthRetrying: isWorthRetrying))
  }
}

/// The modifier behind ``OperationRequest/retry(limit:while:)``.
public struct ConditionalRetryModifier<Operation: OperationRequest>: OperationModifier, Sendable {
  let limit: Int
  let isWorthRetrying: @Sendable (Operation.Failure) -> Bool

  public func setup(context: inout OperationContext, using operation: Operation) {
    context.operationMaxRetries = self.limit
    operation.setup(context: &context)
  }

  public func run(
    isolation: isolated (any Actor)?,
    in context: OperationContext,
    using operation: Operation,
    with continuation: OperationContinuation<Operation.Value, Operation.Failure>
  ) async throws(Operation.Failure) -> Operation.Value {
    var context = context
    for index in 0..<self.limit {
      context.operationRetryIndex = index == 0 ? nil : index - 1
      do {
        return try await operation.run(isolation: isolation, in: context, with: continuation)
      } catch {
        guard self.isWorthRetrying(error) else { throw error }
        try? await context.operationDelayer
          .delay(for: context.operationBackoffFunction(index + 1))
      }
    }
    context.operationRetryIndex = self.limit > 0 ? self.limit - 1 : nil
    return try await operation.run(isolation: isolation, in: context, with: continuation)
  }
}
