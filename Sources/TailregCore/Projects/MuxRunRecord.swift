import Foundation
import SQLiteData
import UUIDV7

/// How a project runtime was published.
///
/// This is recorded rather than inferred from whether a binding exists. The two states are
/// otherwise indistinguishable after the fact, and a binding that has gone missing is exactly
/// the fault an observing command needs to be able to name.
public enum ProjectExposure: String, Codable, Equatable, Sendable {
  /// Reachable on the tailnet through a root Tailscale binding.
  case tailnet
  /// Reachable only on the MUX's loopback listener.
  case local
}

extension ProjectExposure: QueryBindable, QueryDecodable {}

@Table("muxRuns")
public struct MuxRunRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var projectID: UUIDV7
  public var pid: Int
  /// Identifies the process behind `pid`, so a recycled PID is never mistaken for this MUX.
  /// Nil when the start time could not be read, which leaves the run unverifiable rather than
  /// assumed live.
  public var processStartedAt: Int64?
  public var ingressPort: PortNumber
  public var adminPort: PortNumber
  public var exposure: ProjectExposure
  public var createdAt: Date
  public var endedAt: Date?

  public init(
    id: UUIDV7 = UUIDV7(),
    projectID: UUIDV7,
    pid: Int,
    processStartedAt: Int64? = nil,
    ingressPort: PortNumber,
    adminPort: PortNumber,
    exposure: ProjectExposure = .tailnet,
    createdAt: Date = Date(),
    endedAt: Date? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.pid = pid
    self.processStartedAt = processStartedAt
    self.ingressPort = ingressPort
    self.adminPort = adminPort
    self.exposure = exposure
    self.createdAt = createdAt
    self.endedAt = endedAt
  }

  /// The MUX process this run recorded. A run always has one: the schema requires a PID.
  public var process: RecordedProcess {
    RecordedProcess(recorded: pid, startedAt: processStartedAt)
  }

  /// Whether `pid` still names the process this run recorded.
  ///
  /// False when the start time was never recorded: an unverifiable process is treated as not
  /// ours, so nothing is ever signalled on the strength of a PID number alone.
  public var hasMatchingProcess: Bool { process.liveness == .running }

  /// The project's current runtime, if one is recorded as running.
  public static func live(for projectID: UUIDV7) -> SelectOf<MuxRunRecord> {
    MuxRunRecord
      .where { $0.projectID.eq(projectID) && $0.endedAt.is(nil) }
      .order { $0.createdAt.desc() }
  }
}
