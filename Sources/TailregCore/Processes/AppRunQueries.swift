import Foundation
import SQLiteData
import UUIDV7

extension AppRunRecord.TableColumns {
  public func belongs(to projectID: UUIDV7) -> some QueryExpression<Bool> {
    self.projectID.eq(projectID)
  }
}

extension AppRunRecord {
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
      guard candidate.ownership == .managed,
        let pid = candidate.pid,
        let witness = candidate.processStartedAt
      else { continue }
      guard !processMatches(pid: Int32(pid), startedAt: witness) else { continue }
      if try end(candidate.id, at: date, in: db) { reclaimed.append(candidate) }
    }
    return reclaimed
  }
}
