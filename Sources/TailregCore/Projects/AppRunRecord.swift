import Foundation
import SQLiteData
import UUIDV7

/// Whether Tailreg launched an application, and may therefore stop it.
///
/// An attached application is someone else's process that Tailreg merely routes to. The
/// distinction is what keeps a lifecycle command from signalling a process it does not own.
public enum ApplicationOwnership: String, Codable, Equatable, Sendable {
  case managed
  case attached
}

extension ApplicationOwnership: QueryBindable, QueryDecodable {}

/// One run of one application under a project.
///
/// Routes describe what the MUX serves; this describes what Tailreg started and is responsible
/// for stopping. A route cannot carry that on its own: it survives a restart in place, it says
/// nothing about ownership, and an application configured with `expose = false` has no route at
/// all yet still has a process.
@Table("appRuns")
public struct AppRunRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var projectID: UUIDV7
  public var name: String
  public var ownership: ApplicationOwnership
  public var routeID: UUIDV7?
  /// The root Tailscale binding this run was published under. A binding stays bound for as
  /// long as a live run references it, so this is the reference.
  public var bindingID: UUIDV7?
  public var pid: Int?
  public var processGroupID: Int?
  /// Identifies the process behind `pid`, so a recycled PID is never mistaken for this run.
  /// Nil when the start time could not be read, which leaves the run unverifiable rather than
  /// assumed live.
  public var processStartedAt: Int64?
  public var createdAt: Date
  public var endedAt: Date?

  public init(
    id: UUIDV7 = UUIDV7(),
    projectID: UUIDV7,
    name: String,
    ownership: ApplicationOwnership,
    routeID: UUIDV7? = nil,
    bindingID: UUIDV7? = nil,
    pid: Int? = nil,
    processGroupID: Int? = nil,
    processStartedAt: Int64? = nil,
    createdAt: Date = Date(),
    endedAt: Date? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.name = name
    self.ownership = ownership
    self.routeID = routeID
    self.bindingID = bindingID
    self.pid = pid
    self.processGroupID = processGroupID
    self.processStartedAt = processStartedAt
    self.createdAt = createdAt
    self.endedAt = endedAt
  }

  public var isLive: Bool { endedAt == nil }

  /// The process this run recorded, if it has one.
  ///
  /// Nil for an attached run, which is someone else's process and carries no PID by construction.
  public var process: RecordedProcess? {
    guard ownership == .managed, let pid else { return nil }
    return RecordedProcess(recorded: pid, startedAt: processStartedAt)
  }

  /// Whether `pid` still names the process this run recorded.
  ///
  /// False for an attached run, which has no process, and for a managed run whose start time was
  /// never recorded: an unverifiable process is treated as not ours, so nothing is ever signalled
  /// on the strength of a PID number alone.
  public var hasMatchingProcess: Bool { process?.liveness == .running }
}

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
    for candidate in candidates where candidate.process?.liveness == .gone {
      if try end(candidate.id, at: date, in: db) { reclaimed.append(candidate) }
    }
    return reclaimed
  }
}
