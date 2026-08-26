public struct TailscaleInstallation: Sendable, Equatable {
  public let binaryPath: String
  public let version: String
  public let backendState: String
  public let dnsName: String

  public init(binaryPath: String, version: String, backendState: String, dnsName: String) {
    self.binaryPath = binaryPath
    self.version = version
    self.backendState = backendState
    self.dnsName = dnsName
  }

  public var isRunning: Bool { backendState == "Running" }
}
