import Foundation
import TailregCore
import Testing

@Suite
struct `Loopback URL tests` {
  @Test(
    arguments: [
      ("http://127.0.0.1:3000", "127.0.0.1", 3000),
      ("http://localhost:8080/api", "localhost", 8080),
      ("https://127.0.0.1:8443", "127.0.0.1", 8443),
      ("http://[::1]:3000", "::1", 3000)
    ]
  )
  func `Accepts a loopback URL and resolves its port`(
    text: String,
    host: String,
    port: Int
  ) throws {
    let loopback = try #require(LoopbackURL(URL(string: text)!))
    #expect(loopback.host == host)
    #expect(loopback.port == PortNumber(port))
    #expect(loopback.description == text)
  }

  /// A URL a browser would follow without a port still names a listener, so the scheme's default
  /// is the port rather than a reason to reject it.
  @Test
  func `A scheme without an explicit port still resolves one`() throws {
    #expect(LoopbackURL(URL(string: "http://localhost")!)?.port == PortNumber(80))
    #expect(LoopbackURL(URL(string: "https://127.0.0.1")!)?.port == PortNumber(443))
  }

  @Test(
    arguments: [
      "http://example.com:8080",
      "http://192.168.1.10:8080",
      "ws://127.0.0.1:8080",
      "file:///tmp/socket",
      "127.0.0.1:8080"
    ]
  )
  func `Refuses anything that is not loopback HTTP`(text: String) {
    // A string Foundation cannot parse at all is refused the same way, rather than trapping on
    // the way in: `--attach` hands this whatever the user typed.
    #expect(URL(string: text).flatMap(LoopbackURL.init) == nil)
  }

  @Test
  func `A port names the plain HTTP upstream of a launched process`() throws {
    let port = try #require(PortNumber(4321))
    let loopback = LoopbackURL(port: port)
    #expect(loopback.url.absoluteString == "http://127.0.0.1:4321")
    #expect(loopback.host == "127.0.0.1")
    #expect(loopback == LoopbackURL(URL(string: "http://127.0.0.1:4321")!))
  }
}
