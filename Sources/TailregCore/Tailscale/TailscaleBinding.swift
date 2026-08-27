import Foundation
import UUIDV7

public enum TailscaleServeTarget: Sendable, Equatable {
  case localPort(Int)
  case proxy(String)
  case path(String)
  case text(String)
}

public enum TailscaleBindingStatus: String, Sendable, Codable, CaseIterable, Equatable {
  case pending
  case active
  case ended
}

public enum TailscaleBindingEndReason: String, Sendable, Codable, CaseIterable, Equatable {
  case unbound
  case expired
  case failed
}

public struct TailscaleBinding: Sendable, Equatable {
  public let hostname: String
  public let tailnetPort: Int
  public let proto: TailscaleServeProtocol
  public let mountPath: String
  public let target: TailscaleServeTarget
  public let funnel: Bool
  public var recordID: UUIDV7?

  public init(
    hostname: String,
    tailnetPort: Int,
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

  public var localPort: Int? {
    guard case .localPort(let port) = target else { return nil }
    return port
  }

  public var url: URL? {
    guard let scheme = proto.urlScheme else { return nil }
    let isDefaultPort =
      (scheme == "https" && tailnetPort == 443) || (scheme == "http" && tailnetPort == 80)
    let authority = isDefaultPort ? hostname : "\(hostname):\(tailnetPort)"
    return URL(string: "\(scheme)://\(authority)\(mountPath)")
  }
}
