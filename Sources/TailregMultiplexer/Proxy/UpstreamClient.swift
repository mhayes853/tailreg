import AsyncHTTPClient
import NIOCore

/// The client the MUX forwards requests with.
///
/// `HTTPClient.shared` is configured to behave like a browser: it follows up to twenty redirects
/// and decompresses bodies. Both are wrong for a proxy. A dev server answering
/// `302 Location: /login` has to reach the browser as a redirect, and a cross-origin `Location`
/// would otherwise have the MUX fetch a foreign host on the client's behalf.
enum UpstreamClient {
  /// Lives as long as the process, exactly as `HTTPClient.shared` would.
  ///
  /// `HTTPClient` traps in `deinit` unless it has been shut down first, and there is no point in
  /// a MUX's life at which proxying is known to be over, so this one is deliberately never shut
  /// down rather than owned by something that would have to guess.
  static let shared: HTTPClient = {
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    configuration.decompression = .disabled
    // A connect limit bounds an upstream that is not there, and it is short because upstreams
    // are loopback: a connection either succeeds at once or is refused, and the pool keeps
    // retrying a refusal until this deadline. No read limit, because server-sent events and long
    // polls are supposed to stay quiet for as long as they like.
    configuration.timeout = HTTPClient.Configuration.Timeout(connect: .seconds(3))
    return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
  }()
}
