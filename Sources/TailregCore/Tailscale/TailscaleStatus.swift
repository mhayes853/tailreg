import Foundation

public struct TailscaleStatus: Sendable, Equatable, Decodable {
  public let version: String
  public let backendState: String
  public let dnsName: String

  public init(version: String, backendState: String, dnsName: String) {
    self.version = version
    self.backendState = backendState
    self.dnsName = dnsName
  }

  public var isRunning: Bool { backendState == "Running" }

  private enum CodingKeys: String, CodingKey {
    case version = "Version"
    case backendState = "BackendState"
    case selfNode = "Self"
  }

  private struct SelfNode: Decodable {
    let dnsName: String?

    private enum CodingKeys: String, CodingKey { case dnsName = "DNSName" }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
    backendState = try container.decodeIfPresent(String.self, forKey: .backendState) ?? ""

    let reported = try container.decodeIfPresent(SelfNode.self, forKey: .selfNode)?.dnsName ?? ""
    dnsName = reported.hasSuffix(".") ? String(reported.dropLast()) : reported
  }
}
