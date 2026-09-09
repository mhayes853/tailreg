import Foundation
import SQLiteData
import UUIDV7

/// How a run ended.
///
/// A run is written before it can know its own answer, so `inProgress` is a real state rather
/// than a gap: a command killed mid-flight leaves one behind, and that is the evidence that it
/// was killed.
public enum RunOutcome: String, Codable, Equatable, Sendable {
  case inProgress = "in-progress"
  case complete
  case failed
}

extension RunOutcome: QueryBindable, QueryDecodable {}

/// One invocation of a Tailreg command.
@Table("commandRuns")
public struct CommandRunRecord: Hashable, Sendable {
  public let id: UUIDV7
  /// Nil until the invocation has resolved a project, and for `status --all`, which has no one
  /// project to attribute itself to.
  public var projectID: UUIDV7?
  public var command: String
  public var pid: Int
  public var startedAt: Date
  public var completedAt: Date?
  public var outcome: RunOutcome
  public var failure: String?

  public init(
    id: UUIDV7 = UUIDV7(),
    projectID: UUIDV7? = nil,
    command: String,
    pid: Int = Int(ProcessInfo.processInfo.processIdentifier),
    startedAt: Date = Date(),
    completedAt: Date? = nil,
    outcome: RunOutcome = .inProgress,
    failure: String? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.command = command
    self.pid = pid
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.outcome = outcome
    self.failure = failure
  }
}

/// Every attempt one operation made during a command run, folded into a single row.
///
/// `attempts` is what a polling operation contributes: `poll` runs its operation once per tick,
/// and three hundred ticks are three hundred attempts at one thing. Only an operation with no
/// operations of its own is folded this way, so a parent never loses the children that named it.
@Table("operationRuns")
public struct OperationRunRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var commandRunID: UUIDV7
  /// The operation this one ran inside, or nil for one the command started directly.
  public var parentID: UUIDV7?
  public var operation: String
  public var attempts: Int
  public var durationMilliseconds: Int
  public var startedAt: Date
  public var outcome: RunOutcome
  public var failure: String?

  public init(
    id: UUIDV7 = UUIDV7(),
    commandRunID: UUIDV7,
    parentID: UUIDV7? = nil,
    operation: String,
    attempts: Int = 1,
    durationMilliseconds: Int,
    startedAt: Date = Date(),
    outcome: RunOutcome = .complete,
    failure: String? = nil
  ) {
    self.id = id
    self.commandRunID = commandRunID
    self.parentID = parentID
    self.operation = operation
    self.attempts = attempts
    self.durationMilliseconds = durationMilliseconds
    self.startedAt = startedAt
    self.outcome = outcome
    self.failure = failure
  }
}

extension CommandRunRecord {
  /// The most recent invocations of any command for a project, newest first.
  public static func recent(for projectID: UUIDV7, limit: Int = 20) -> Where<CommandRunRecord> {
    Self.where { $0.projectID.eq(projectID) }
  }
}

extension OperationRunRecord {
  /// Everything one invocation did, in the order it started doing it.
  public static func all(of commandRunID: UUIDV7) -> Where<OperationRunRecord> {
    Self.where { $0.commandRunID.eq(commandRunID) }
  }
}
