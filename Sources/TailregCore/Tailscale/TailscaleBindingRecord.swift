import Foundation
import SQLiteData
import UUIDV7

@Table("bindings")
public struct TailscaleBindingRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var hostname: String
  public var localPort: PortNumber
  public var tailnetPort: PortNumber
  public var proto: TailscaleServeProtocol
  public var mountPath: String
  public var status: TailscaleBindingStatus
  public var createdAt: Date
  public var endedAt: Date?
  public var endReason: TailscaleBindingEndReason?

  public init(
    id: UUIDV7 = UUIDV7(),
    hostname: String,
    localPort: PortNumber,
    tailnetPort: PortNumber,
    proto: TailscaleServeProtocol,
    mountPath: String,
    status: TailscaleBindingStatus = .pending,
    createdAt: Date,
    endedAt: Date? = nil,
    endReason: TailscaleBindingEndReason? = nil
  ) {
    self.id = id
    self.hostname = hostname
    self.localPort = localPort
    self.tailnetPort = tailnetPort
    self.proto = proto
    self.mountPath = mountPath
    self.status = status
    self.createdAt = createdAt
    self.endedAt = endedAt
    self.endReason = endReason
  }

  public var isLive: Bool { endedAt == nil }

  /// The URL this binding was recorded as serving.
  public var url: URL? {
    tailscaleURL(
      hostname: hostname,
      tailnetPort: tailnetPort,
      proto: proto,
      mountPath: mountPath
    )
  }

  func claims(_ binding: TailscaleBinding) -> Bool {
    binding.tailnetPort == tailnetPort
      && binding.proto == proto
      && binding.mountPath == mountPath
      && binding.localPort == localPort
  }

  /// The bindings currently serving a local port, oldest first.
  public static func live(localPort: PortNumber) -> SelectOf<TailscaleBindingRecord> {
    TailscaleBindingRecord
      .where { $0.localPort.eq(localPort) && $0.endedAt.is(nil) }
      .order { $0.createdAt }
  }
}
