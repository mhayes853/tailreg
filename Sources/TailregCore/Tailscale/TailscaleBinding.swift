import Foundation
import SQLiteData
import UUIDV7

public enum TailscaleServeTarget: Sendable, Equatable {
  case localPort(PortNumber)
  case proxy(String)
  case path(String)
  case text(String)
}

public enum TailscaleBindingStatus: String, Sendable, Codable, CaseIterable, Equatable {
  case pending
  case active
  case ended
}

extension TailscaleBindingStatus: QueryBindable, QueryDecodable {}

public enum TailscaleBindingEndReason: String, Sendable, Codable, CaseIterable, Equatable {
  case unbound
  case expired
  case failed
}

extension TailscaleBindingEndReason: QueryBindable, QueryDecodable {}

public struct TailscaleBinding: Sendable, Equatable {
  public let hostname: String
  public let tailnetPort: PortNumber
  public let proto: TailscaleServeProtocol
  public let mountPath: String
  public let target: TailscaleServeTarget
  public let funnel: Bool
  public var recordID: UUIDV7?

  public init(
    hostname: String,
    tailnetPort: PortNumber,
    proto: TailscaleServeProtocol,
    mountPath: String,
    target: TailscaleServeTarget,
    funnel: Bool,
    recordID: UUIDV7? = nil
  ) {
    self.hostname = hostname
    self.tailnetPort = tailnetPort
    self.proto = proto
    self.mountPath = mountPath
    self.target = target
    self.funnel = funnel
    self.recordID = recordID
  }

  public var isManaged: Bool { recordID != nil }

  public var localPort: PortNumber? {
    guard case .localPort(let port) = target else { return nil }
    return port
  }

  public var url: URL? {
    tailscaleURL(
      hostname: hostname,
      tailnetPort: tailnetPort,
      proto: proto,
      mountPath: mountPath
    )
  }
}

/// Builds the URL a serve target is reachable on.
///
/// Shared by the live binding and the record of one, so an observed binding and a recorded
/// binding can never disagree about the URL they describe.
func tailscaleURL(
  hostname: String,
  tailnetPort: PortNumber,
  proto: TailscaleServeProtocol,
  mountPath: String
) -> URL? {
  guard let scheme = proto.urlScheme else { return nil }
  let isDefaultPort =
    (scheme == "https" && tailnetPort.rawValue == 443)
    || (scheme == "http" && tailnetPort.rawValue == 80)
  let authority = isDefaultPort ? hostname : "\(hostname):\(tailnetPort)"
  return URL(string: "\(scheme)://\(authority)\(mountPath)")
}
