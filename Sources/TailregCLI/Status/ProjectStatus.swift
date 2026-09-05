import Foundation
import TailregCore
import UUIDV7

/// One `status` report.
///
/// Always a list, even for a single project, so `--all` adds elements rather than changing the
/// shape of the output that anything is already parsing.
struct StatusReport: Codable, Equatable, Sendable {
  var projects: [ProjectStatus]
}

/// What is configured, what is recorded, and what is actually there, for one project.
///
/// The three rarely disagree, and this exists for when they do: every field is either an
/// observation or a record, and `problems` is where the two are reconciled.
struct ProjectStatus: Codable, Equatable, Sendable {
  var name: String
  var root: String
  /// Where the project is reachable. Nil when it is not running, and also when it should be
  /// reachable on the tailnet but no binding is recorded — which is a problem, not a URL.
  var url: URL? = nil
  var exposure: ProjectExposure? = nil
  /// Every root binding recorded for the runtime, with the applications holding each.
  var bindings: [BindingStatus] = []
  var mux: MuxStatus
  var applications: [ApplicationStatus]
  var problems: [StatusProblem]
}

struct BindingStatus: Codable, Equatable, Sendable {
  var id: UUIDV7
  var url: URL?
  var tailnetPort: Int
  /// The live runs that keep this binding bound. Empty is a problem: teardown would have
  /// removed it.
  var holders: [String]
}

struct MuxStatus: Codable, Equatable, Sendable {
  enum State: String, Codable, Sendable {
    /// The admin API answered.
    case running
    /// The recorded process is alive but its admin API is not answering.
    case unreachable
    /// The recorded process is gone.
    case stale
    case notRunning = "not-running"
  }

  var state: State
  var pid: Int? = nil
  var ingressPort: Int? = nil
  var adminPort: Int? = nil
  var startedAt: Date? = nil
}

struct ApplicationStatus: Codable, Equatable, Sendable {
  /// Each case is a distinction the runtime already draws, rather than one invented for display.
  enum State: String, Codable, Sendable {
    /// A managed process whose identity still matches, or an attached upstream that answers.
    case running
    /// A live record whose process is provably gone. What `reclaimAbandoned` would clear.
    case stale
    /// A live managed record with no recorded start time, so its identity cannot be confirmed
    /// either way. What `reclaimAbandoned` deliberately leaves alone.
    case unverified
    /// An attached application whose upstream is not listening.
    case unreachable
    /// Configured, with no live run.
    case stopped
  }

  var name: String
  var state: State
  var ownership: ApplicationOwnership? = nil
  /// Whether `tailreg.toml` still describes this application.
  var configured: Bool
  /// Whether the configuration asks for a route at all. Nil when nothing configures it.
  var isExposed: Bool? = nil
  var pid: Int? = nil
  var processGroupID: Int? = nil
  var startedAt: Date? = nil
  var route: RouteStatus? = nil
}

struct RouteStatus: Codable, Equatable, Sendable {
  var id: UUIDV7
  var path: String
  var url: URL?
  var upstreamURL: String
  var pathMode: MuxRoutePathMode
}

/// One disagreement between what is configured, what is recorded, and what is there.
///
/// The human and JSON views render this same list, so the two cannot come to different
/// conclusions about whether a project is healthy.
struct StatusProblem: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case missing
    case unreachable
    case staleProcess = "stale-process"
    case notListening = "not-listening"
    case notConfigured = "not-configured"
    case orphanedRoute = "orphaned-route"
    case unheldBinding = "unheld-binding"

    var label: String {
      switch self {
      case .missing: "missing"
      case .unreachable: "unreachable"
      case .staleProcess: "stale process"
      case .notListening: "not listening"
      case .notConfigured: "not configured"
      case .orphanedRoute: "orphaned route"
      case .unheldBinding: "unheld binding"
      }
    }
  }

  var subject: String
  var kind: Kind
  var detail: String
}
