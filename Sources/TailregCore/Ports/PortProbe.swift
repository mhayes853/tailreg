/// Answers whether *anything* is accepting connections on an address.
///
/// This is deliberately a different question from ``ListeningProcessLocator``: a probe
/// succeeds for ports owned by other users, other network namespaces and remote hosts, none
/// of which a locator can attribute to a process.
public protocol PortProbe: Sendable {
  func isListening(host: String, port: PortNumber) async -> Bool
}

extension PortProbe {
  public func isListening(port: PortNumber) async -> Bool {
    await isListening(host: "127.0.0.1", port: port)
  }
}
