public enum TailscaleServeProtocol: String, Sendable, Codable, CaseIterable, Equatable {
  case https
  case http
  case tcp
  case tlsTerminatedTCP = "tls-terminated-tcp"

  public var flagName: String { "--\(rawValue)" }

  public var urlScheme: String? {
    switch self {
    case .https: "https"
    case .http: "http"
    case .tcp, .tlsTerminatedTCP: nil
    }
  }
}

public enum TailscaleTailnetPort: Sendable, Equatable {
  case auto
  case explicit(Int)

  public static let autoAllocationPool = [443, 8443, 10000]
}
