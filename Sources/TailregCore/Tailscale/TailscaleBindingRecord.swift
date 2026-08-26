import Foundation

struct TailscaleBindingRecord: Codable, Sendable, Equatable {
  let localPort: Int
  let tailnetPort: Int
  let proto: TailscaleServeProtocol
  let mountPath: String
  let createdAt: Date

  func claims(_ binding: TailscaleBinding) -> Bool {
    binding.tailnetPort == tailnetPort
      && binding.proto == proto
      && binding.mountPath == mountPath
      && binding.localPort == localPort
  }
}
