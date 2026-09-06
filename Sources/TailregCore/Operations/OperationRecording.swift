import Foundation
import Operation
import SQLiteData
import UUIDV7

extension OperationRequest {
  /// Reports this operation's run to a recorder.
  ///
  /// Apply this through ``OperationRecordingTransform`` rather than by hand. The transform wraps
  /// every operation run in its scope exactly once, and a second application would record the
  /// same run twice under two identities.
  public func recorded(
    to recorder: OperationRecorder
  ) -> ModifiedOperation<Self, _RecordingModifier<Self>> {
    self.modifier(_RecordingModifier(recorder: recorder))
  }
}

public struct _RecordingModifier<Operation: OperationRequest>: OperationModifier, Sendable {
  let recorder: OperationRecorder

  public func run(
    isolation: isolated (any Actor)?,
    in context: OperationContext,
    using operation: Operation,
    with continuation: OperationContinuation<Operation.Value, Operation.Failure>
  ) async throws(Operation.Failure) -> Operation.Value {
    let id = UUIDV7()
    let parentID = OperationRecorder.parent
    let startedAt = Date()
    let clock = context.operationClock
    let start = clock.now()

    func entry(_ outcome: RunOutcome, failure: String? = nil) -> OperationRecorder.Entry {
      OperationRecorder.Entry(
        id: id,
        parentID: parentID,
        operation: operation._debugTypeName,
        startedAt: startedAt,
        duration: .seconds(clock.now().timeIntervalSince(start)),
        outcome: outcome,
        failure: failure
      )
    }

    // The run is caught rather than allowed to propagate, because a task local's `withValue`
    // throws untyped and would widen this operation's failure type on the way back out.
    let result = await OperationRecorder.$parent.withValue(
      id,
      // Anything this operation runs in turn finds that identifier and records itself as a
      // child, which is what makes one invocation read as a tree rather than a list.
      operation: {
        await Result(isolation: isolation) { () async throws(Operation.Failure) in
          try await operation.run(isolation: isolation, in: context, with: continuation)
        }
      },
      isolation: isolation
    )

    switch result {
    case .success(let value):
      await self.recorder.record(entry(.complete))
      return value
    case .failure(let error):
      await self.recorder.record(
        entry(.failed, failure: String(String(describing: error).prefix(1_000)))
      )
      throw error
    }
  }
}

extension Result {
  /// The outcome of an operation that keeps its thrown type, which `init(catching:)` erases.
  fileprivate init(
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws(Failure) -> Success
  ) async {
    do {
      self = .success(try await body())
    } catch {
      self = .failure(error)
    }
  }
}

/// Records every operation run in its scope.
///
/// Installed once per command invocation rather than at each call site, which is the point: an
/// operation added later is recorded because it is an operation, not because somebody remembered
/// to record it.
public struct OperationRecordingTransform: OperationTransform {
  let recorder: OperationRecorder

  public init(recorder: OperationRecorder) {
    self.recorder = recorder
  }

  public func apply<Operation: OperationRequest>(
    to operation: Operation
  ) -> any OperationRequest<Operation.Value, Operation.Failure> {
    operation.recorded(to: self.recorder)
  }
}

/// Runs one command invocation with its operations recorded.
///
/// The `commandRuns` row is written before the work starts, so an invocation that is killed
/// leaves evidence that it began. Recording is never allowed to fail the command: a report
/// nobody can write is worth less than the command it would have taken down with it.
public func recordingCommandRun<T>(
  _ command: String,
  in database: any DatabaseWriter,
  operation: (OperationRecorder) async throws -> T
) async throws -> T {
  let recorder = OperationRecorder()
  var run = CommandRunRecord(command: command)
  let started = run
  try? await database.write { database in
    try CommandRunRecord.insert { started }.execute(database)
  }
  do {
    let value = try await withOperationTransform(OperationRecordingTransform(recorder: recorder)) {
      try await operation(recorder)
    }
    run.outcome = .complete
    await finish(run, recorder: recorder, in: database)
    return value
  } catch {
    run.outcome = .failed
    run.failure = String(String(describing: error).prefix(1_000))
    await finish(run, recorder: recorder, in: database)
    throw error
  }
}

private func finish(
  _ run: CommandRunRecord,
  recorder: OperationRecorder,
  in database: any DatabaseWriter
) async {
  try? await recorder.flush(as: run.id, to: database)
  let projectID = await recorder.projectID
  let completedAt = Date()
  let outcome = run.outcome
  let failure = run.failure
  try? await database.write { database in
    try CommandRunRecord.find(run.id)
      .update {
        $0.completedAt = #bind(completedAt)
        $0.outcome = #bind(outcome)
        $0.failure = #bind(failure)
        $0.projectID = #bind(projectID)
      }
      .execute(database)
  }
}
