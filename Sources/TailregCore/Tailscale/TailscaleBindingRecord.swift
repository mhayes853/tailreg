import Foundation

public struct TailscaleBindingRecord: Codable, Sendable, Equatable {
  public let localPort: Int
  public let tailnetPort: Int
  public let proto: TailscaleServeProtocol
  public let mountPath: String
  public let createdAt: Date

  public init(
    localPort: Int,
    tailnetPort: Int,
    proto: TailscaleServeProtocol,
    mountPath: String,
    createdAt: Date
  ) {
    self.localPort = localPort
    self.tailnetPort = tailnetPort
    self.proto = proto
    self.mountPath = mountPath
    self.createdAt = createdAt
  }

  public func claims(_ binding: TailscaleBinding) -> Bool {
    binding.tailnetPort == tailnetPort
      && binding.proto == proto
      && binding.mountPath == mountPath
      && binding.localPort == localPort
  }
}
