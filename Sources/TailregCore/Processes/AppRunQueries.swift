import Foundation
import SQLiteData
import UUIDV7

extension AppRunRecord.TableColumns {
  public func belongs(to projectID: UUIDV7) -> some QueryExpression<Bool> {
    self.projectID.eq(projectID)
  }
}

extension AppRunRecord {
  /// Whether `pid` still names the process this run recorded.
  ///
  /// False for an attached run, which has no process, and for a managed run whose start time was
  /// never recorded: an unverifiable process is treated as not ours, so nothing is ever signalled
  /// on the strength of a PID number alone.
  public var hasMatchingProcess: Bool {
    guard ownership == .managed, let pid else { return false }
    return processMatches(pid: Int32(pid), startedAt: processStartedAt)
  }

  public static func live(for projectID: UUIDV7) -> SelectOf<AppRunRecord> {
    AppRunRecord
      .where { $0.belongs(to: projectID) && $0.endedAt.is(nil) }
      .order { ($0.name, $0.createdAt) }
  }

  public static func live(for projectID: UUIDV7, name: String) -> SelectOf<AppRunRecord> {
    AppRunRecord
      .where { $0.belongs(to: projectID) && $0.name.eq(name) && $0.endedAt.is(nil) }
      .order { $0.createdAt }
  }

  /// Ends this run, reporting whether *this* caller is the one that ended it.
  ///
  /// The update is conditional on the run still being live, so exactly one of several racing
  /// supervisors wins. Only the winner should go on to remove the run's route: without this,
  /// a supervisor whose application has been replaced would tear down its successor's route,
  /// since a route survives a restart in place and so cannot identify its owner.
  public static func end(
    _ id: UUIDV7,
    at date: Date = Date(),
    in db: Database
  ) throws -> Bool {
    try AppRunRecord
      .where { $0.id.eq(id) && $0.endedAt.is(nil) }
      .update { $0.endedAt = #bind(date) }
      .execute(db)
    return db.changesCount == 1
  }

  /// Ends live runs whose process is provably gone, so a crashed supervisor's records do not
  /// keep an application marked as running forever.
  ///
  /// A run is only reclaimed when its identity can be *disproved*: an attached run has no
  /// process to check, and a managed run recorded without a start time cannot be confirmed
  /// either way. Both are left alone rather than being assumed dead.
  @discardableResult
  public static func reclaimAbandoned(
    for projectID: UUIDV7,
    at date: Date = Date(),
    in db: Database
  ) throws -> [AppRunRecord] {
    let candidates = try live(for: projectID).fetchAll(db)
    var reclaimed: [AppRunRecord] = []
    for candidate in candidates {
      // Only a process that can be disproved is reclaimed. `hasMatchingProcess` is also false for
      // a run that merely cannot be verified, which must be left alone.
      guard candidate.processStartedAt != nil, !candidate.hasMatchingProcess else { continue }
      if try end(candidate.id, at: date, in: db) { reclaimed.append(candidate) }
    }
    return reclaimed
  }
}
