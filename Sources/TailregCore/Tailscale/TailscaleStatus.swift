import Foundation

struct TailscaleStatus: Sendable, Equatable, Decodable {
  let backendState: String
  let dnsName: String

  var isRunning: Bool { backendState == "Running" }

  private enum CodingKeys: String, CodingKey {
    case backendState = "BackendState"
    case selfNode = "Self"
  }

  private struct SelfNode: Decodable {
    let dnsName: String?

    private enum CodingKeys: String, CodingKey { case dnsName = "DNSName" }
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    backendState = try container.decodeIfPresent(String.self, forKey: .backendState) ?? ""

    let reported = try container.decodeIfPresent(SelfNode.self, forKey: .selfNode)?.dnsName ?? ""
    dnsName = reported.hasSuffix(".") ? String(reported.dropLast()) : reported
  }
}
