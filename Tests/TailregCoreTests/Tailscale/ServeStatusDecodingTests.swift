import Foundation
import TailregCore
import Testing

@Suite
struct `Serve status decoding tests` {
  private func bindings(
    from serveStatus: String,
    nodeStatus: String = Fixtures.nodeStatus
  ) async throws -> [TailscaleBinding] {
    let temp = try TempDirectory()
    let runner = StubProcessRunner()
    runner.stub(["status", "--json"], stdout: nodeStatus)
    runner.stub(["serve", "status", "--json"], stdout: serveStatus)

    return try await TailscaleBinder(
      binaryPath: "/usr/bin/tailscale",
      runner: runner,
      portProbe: StubPortProbe(),
      registryPath: temp.path("bindings.json")
    )
    .bindings()
  }

  @Test
  func `Flattens A Proxy Handler Into A Binding`() async throws {
    let decoded = try await bindings(from: Fixtures.liveServeStatus)

    #expect(decoded.count == 1)
    let binding = try #require(decoded.first)
    #expect(binding.hostname == "omarchy.tailc6bff1.ts.net")
    #expect(binding.tailnetPort == 443)
    #expect(binding.proto == .https)
    #expect(binding.target == .localPort(3773))
    #expect(binding.isManaged == false)
  }

  @Test
  func `Splits One Port Into A Binding Per Mount Path`() async throws {
    let decoded = try await bindings(from: Fixtures.multiPathServeStatus)

    #expect(decoded.map(\.mountPath) == ["/", "/api", "/static"])
    #expect(decoded.allSatisfy { $0.tailnetPort == 8443 })
    #expect(decoded.allSatisfy { $0.funnel })
  }

  @Test
  func `Treats Localhost As A Loopback Target`() async throws {
    let api = try #require(
      try await bindings(from: Fixtures.multiPathServeStatus).first { $0.mountPath == "/api" }
    )

    #expect(api.target == .localPort(9000))
  }

  @Test
  func `Keeps Static Handlers But Reports No Local Port`() async throws {
    let handler = try #require(
      try await bindings(from: Fixtures.multiPathServeStatus).first { $0.mountPath == "/static" }
    )

    #expect(handler.target == .path("/var/www"))
    #expect(handler.localPort == nil)
  }

  @Test
  func `Distinguishes Raw Forwards From TLS Terminated Ones`() async throws {
    let decoded = try await bindings(from: Fixtures.tcpForwardServeStatus)

    let raw = try #require(decoded.first { $0.tailnetPort == 2222 })
    #expect(raw.proto == .tcp)
    #expect(raw.target == .localPort(22))

    let terminated = try #require(decoded.first { $0.tailnetPort == 10000 })
    #expect(terminated.proto == .tlsTerminatedTCP)
  }

  @Test
  func `Names TCP Forwards With The Nodes DNS Name Minus Its Trailing Dot`() async throws {
    let decoded = try await bindings(from: Fixtures.tcpForwardServeStatus)

    #expect(decoded.allSatisfy { $0.hostname == "omarchy.tailc6bff1.ts.net" })
  }

  @Test
  func `Ignores A TCP Entry That Only Terminates TLS For A Web Handler`() async throws {
    #expect(try await bindings(from: Fixtures.liveServeStatus).count == 1)
  }

  @Test
  func `Reads Every Shape An Unconfigured Node Emits`() async throws {
    for text in ["{}", "null", "", "  \n"] {
      #expect(try await bindings(from: text).isEmpty)
    }
  }

  @Test
  func `Surfaces Malformed Output As A Tailscale Error`() async {
    await #expect(throws: TailscaleError.self) {
      try await bindings(from: "{ not json")
    }
  }

  @Test
  func `Orders Bindings By Port Rather Than JSON Key Order`() async throws {
    #expect(
      try await bindings(from: Fixtures.tcpForwardServeStatus).map(\.tailnetPort) == [2222, 10000]
    )
  }
}
