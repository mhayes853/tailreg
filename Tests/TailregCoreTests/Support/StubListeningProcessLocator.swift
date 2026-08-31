import TailregCore

struct StubListeningProcessLocator: ListeningProcessLocator {
  var processesByPort: [PortNumber: [ListeningProcess]]
  var failure: ListeningProcessError?

  init(
    processesByPort: [PortNumber: [ListeningProcess]] = [:],
    failure: ListeningProcessError? = nil
  ) {
    self.processesByPort = processesByPort
    self.failure = failure
  }

  func processes(listeningOn port: PortNumber) async throws -> [ListeningProcess] {
    if let failure { throw failure }
    return processesByPort[port] ?? []
  }
}
