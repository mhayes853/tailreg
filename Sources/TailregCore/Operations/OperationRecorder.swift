import Foundation
import SQLiteData
import UUIDV7

/// Collects what each operation in one command invocation did, and writes it once at the end.
///
/// Nothing is written while the command runs. The operations being recorded include readiness
/// polls that tick every hundred milliseconds, and one of them ticks while holding the runtime
/// lock, so a row per attempt would put a serialized database write inside the path that other
/// invocations are waiting on. Attempts at the same operation under the same parent are folded
/// into one row as they arrive, which is also the row a reader wants: "readiness for web, 4.2s
/// over 47 attempts" rather than 47 rows to add up.
///
/// The cost is that a command killed before it flushes loses its operations. Its `commandRuns`
/// row survives, still reading `in-progress`, so the invocation is not lost — only the detail of
/// where it had got to.
public actor OperationRecorder {
  private var entries: [Entry] = []
  private var foldable: [FoldKey: Int] = [:]
  private var parents: Set<UUIDV7> = []

  /// The project this invocation turned out to be about, once it knows.
  ///
  /// A command resolves its project as part of its work rather than before it, and a resolution
  /// that fails is one of the more interesting things to have recorded, so the `commandRuns` row
  /// exists before there is a project to attribute it to.
  public private(set) var projectID: UUIDV7?

  public init() {}

  public func attach(project: UUIDV7) {
    self.projectID = project
  }

  /// Where a nested operation finds the operation it is running inside.
  @TaskLocal static var parent: UUIDV7?

  /// Records one run, folding it into a sibling attempt at the same operation where it can.
  func record(_ entry: Entry) {
    if let parent = entry.parentID { self.parents.insert(parent) }
    let key = FoldKey(parentID: entry.parentID, operation: entry.operation)
    if let index = self.foldable[key], !self.parents.contains(entry.id) {
      self.entries[index].fold(entry)
      return
    }
    self.entries.append(entry)
    // An operation that turns out to have children of its own stops being foldable, but that is
    // only known once a child names it, which has already happened by the time it records.
    if !self.parents.contains(entry.id) { self.foldable[key] = self.entries.count - 1 }
  }

  /// Writes everything collected as the operations of `commandRunID`.
  ///
  /// A child always finishes before the operation containing it, so it is always recorded first;
  /// reversing that order is what puts every parent in the table before the rows referencing it.
  public func flush(as commandRunID: UUIDV7, to database: any DatabaseWriter) async throws {
    let records = self.entries.reversed().map { $0.record(of: commandRunID) }
    self.entries.removeAll()
    self.foldable.removeAll()
    self.parents.removeAll()
    guard !records.isEmpty else { return }
    try await database.write { database in
      for record in records {
        try OperationRunRecord.insert { record }.execute(database)
      }
    }
  }

  struct Entry: Sendable {
    let id: UUIDV7
    let parentID: UUIDV7?
    let operation: String
    let startedAt: Date
    var duration: Duration
    var attempts = 1
    var outcome: RunOutcome
    var failure: String?

    /// Absorbs a later attempt at the same operation.
    ///
    /// The failure kept is the last one seen, because that is the answer the caller acted on: a
    /// poll that eventually succeeds has no failure to report, and one that gave up reports what
    /// it gave up on.
    mutating func fold(_ other: Entry) {
      self.duration += other.duration
      self.attempts += other.attempts
      self.outcome = other.outcome
      self.failure = other.failure
    }

    func record(of commandRunID: UUIDV7) -> OperationRunRecord {
      OperationRunRecord(
        id: self.id,
        commandRunID: commandRunID,
        parentID: self.parentID,
        operation: self.operation,
        attempts: self.attempts,
        durationMilliseconds: max(0, Int(self.duration / .milliseconds(1))),
        startedAt: self.startedAt,
        outcome: self.outcome,
        failure: self.failure
      )
    }
  }

  private struct FoldKey: Hashable {
    let parentID: UUIDV7?
    let operation: String
  }
}
