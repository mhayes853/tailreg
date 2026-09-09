import SQLiteData

public enum TailscaleServeProtocol: String, Sendable, Codable, CaseIterable, Equatable {
  case https
  case http
  case tcp
  case tlsTerminatedTCP = "tls-terminated-tcp"

  var flagName: String { "--\(rawValue)" }

  var urlScheme: String? {
    switch self {
    case .https: "https"
    case .http: "http"
    case .tcp, .tlsTerminatedTCP: nil
    }
  }
}

extension TailscaleServeProtocol: QueryBindable, QueryDecodable {}

public enum TailscaleTailnetPort: Sendable, Equatable {
  case auto
  case explicit(PortNumber)

  public static let autoAllocationPool: [PortNumber] = [
    PortNumber(rawValue: 443)!, PortNumber(rawValue: 8443)!, PortNumber(rawValue: 10000)!
  ]
}
