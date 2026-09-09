import Foundation

/// A URL that names something listening on this machine.
///
/// Tailreg only ever proxies to loopback: an upstream is a process on the same host as the MUX,
/// and a URL pointing anywhere else would publish a third party's server on the user's tailnet.
/// Checking that once, here, is what lets everything downstream take a reachable host and port
/// for granted instead of re-deriving them from an optional `URL.port`.
public struct LoopbackURL: Hashable, Sendable, CustomStringConvertible {
  public let url: URL
  public let host: String
  public let port: PortNumber

  /// Accepts an `http` or `https` URL on a loopback host whose port is known.
  ///
  /// The port may be implied by the scheme rather than written: `http://localhost` is a listener
  /// on port 80, and refusing it would reject a URL a browser would happily follow.
  public init?(_ url: URL) {
    guard url.scheme == "http" || url.scheme == "https",
      let host = url.host,
      Self.loopbackHosts.contains(host),
      let port = url.listenerPort
    else { return nil }
    self.url = url
    self.host = host
    self.port = port
  }

  /// The plain HTTP upstream of a process Tailreg launched, which listens on loopback by
  /// convention and is reached over the loopback interface regardless.
  public init(port: PortNumber) {
    self.url = URL(string: "http://127.0.0.1:\(port)")!
    self.host = "127.0.0.1"
    self.port = port
  }

  /// `::1` is spelled without brackets here because that is how `URL.host` reports it.
  private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

  public var description: String { url.absoluteString }
}
