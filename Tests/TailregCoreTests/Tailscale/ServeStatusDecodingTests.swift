import Foundation
import TailregCore
import Testing

@Suite
struct `Serve status decoding tests` {
  private func decode(
    _ text: String,
    hostname: String = "omarchy.tailc6bff1.ts.net"
  ) throws -> [TailscaleBinding] {
    try TailscaleServeStatus.decode(Fixtures.data(text), hostname: hostname)
  }

  @Test
  func `Flattens A Proxy Handler Into A Binding`() throws {
    let bindings = try decode(Fixtures.liveServeStatus)

    #expect(bindings.count == 1)
    let binding = try #require(bindings.first)
    #expect(binding.hostname == "omarchy.tailc6bff1.ts.net")
    #expect(binding.tailnetPort == 443)
    #expect(binding.proto == .https)
    #expect(binding.target == .localPort(3773))
    #expect(binding.isManaged == false)
  }

  @Test
  func `Splits One Port Into A Binding Per Mount Path`() throws {
    let bindings = try decode(Fixtures.multiPathServeStatus)

    #expect(bindings.map(\.mountPath) == ["/", "/api", "/static"])
    #expect(bindings.allSatisfy { $0.tailnetPort == 8443 })
    #expect(bindings.allSatisfy { $0.funnel })
  }

  @Test
  func `Treats Localhost As A Loopback Target`() throws {
    let api = try #require(
      try decode(Fixtures.multiPathServeStatus).first { $0.mountPath == "/api" }
    )

    #expect(api.target == .localPort(9000))
  }

  @Test
  func `Keeps Static Handlers But Reports No Local Port`() throws {
    let staticHandler = try #require(
      try decode(Fixtures.multiPathServeStatus).first { $0.mountPath == "/static" }
    )

    #expect(staticHandler.target == .path("/var/www"))
    #expect(staticHandler.localPort == nil)
  }

  @Test
  func `Distinguishes Raw Forwards From TLS Terminated Ones`() throws {
    let bindings = try decode(Fixtures.tcpForwardServeStatus)

    let raw = try #require(bindings.first { $0.tailnetPort == 2222 })
    #expect(raw.proto == .tcp)
    #expect(raw.target == .localPort(22))
    #expect(raw.hostname == "omarchy.tailc6bff1.ts.net")

    let terminated = try #require(bindings.first { $0.tailnetPort == 10000 })
    #expect(terminated.proto == .tlsTerminatedTCP)
  }

  @Test
  func `Ignores A TCP Entry That Only Terminates TLS For A Web Handler`() throws {
    #expect(try decode(Fixtures.liveServeStatus).count == 1)
  }

  @Test
  func `Reads Every Shape An Unconfigured Node Emits`() throws {
    for text in ["{}", "null", "", "  \n"] {
      #expect(try decode(text).isEmpty)
    }
  }

  @Test
  func `Surfaces Malformed Output As A Tailscale Error`() {
    #expect(throws: TailscaleError.self) {
      try decode("{ not json")
    }
  }

  @Test
  func `Orders Bindings By Port Rather Than JSON Key Order`() throws {
    #expect(try decode(Fixtures.tcpForwardServeStatus).map(\.tailnetPort) == [2222, 10000])
  }
}
