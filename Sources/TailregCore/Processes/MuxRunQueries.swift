import Foundation
import SQLiteData
import UUIDV7

extension MuxRunRecord {
  /// The project's current runtime, if one is recorded as running.
  public static func live(for projectID: UUIDV7) -> SelectOf<MuxRunRecord> {
    MuxRunRecord
      .where { $0.projectID.eq(projectID) && $0.endedAt.is(nil) }
      .order { $0.createdAt.desc() }
  }

  /// Whether `pid` still names the process this run recorded.
  ///
  /// False when the start time was never recorded: an unverifiable process is treated as not
  /// ours, so nothing is ever signalled on the strength of a PID number alone.
  public var hasMatchingProcess: Bool {
    processMatches(pid: Int32(pid), startedAt: processStartedAt)
  }
}
