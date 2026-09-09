import TailregCore

public struct StubListeningProcessLocator: ListeningProcessLocator {
  public var processesByPort: [PortNumber: [ListeningProcess]]
  public var failure: ListeningProcessError?

  public init(
    processesByPort: [PortNumber: [ListeningProcess]] = [:],
    failure: ListeningProcessError? = nil
  ) {
    self.processesByPort = processesByPort
    self.failure = failure
  }

  public func processes(listeningOn port: PortNumber) async throws -> [ListeningProcess] {
    if let failure { throw failure }
    return processesByPort[port] ?? []
  }
}
