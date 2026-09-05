import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import TailregCore
import TailregMultiplexer
import TailregTestSupport
import Testing

/// What the upstream saw, so a test can assert on the request the MUX actually forwarded.
private struct EchoedRequest: ResponseCodable, Equatable {
  var path: String
  var headers: [String: [String]]
}

@Suite
struct `MUX proxy tests` {
  private static let route = MuxRouteName(rawValue: "app")!
  /// Bytes that are not gzip: a client that decompressed them would fail rather than pass them
  /// on, which is exactly what must not happen here.
  private static let opaqueBody: [UInt8] = [0x1f, 0x8b, 0x00, 0x01, 0x02, 0xff, 0xfe, 0x7f]

  @Test
  func `An upstream redirect reaches the client instead of being followed`() async throws {
    try await withProxiedUpstream { client in
      try await client.execute(uri: "/app/redirect", method: .get) { response in
        #expect(response.status == .found)
        #expect(response.headers[.location] == "/login")
        #expect(response.body.readableBytes == 0)
      }
    }
  }

  @Test
  func `An encoded response body is passed through with its encoding intact`() async throws {
    try await withProxiedUpstream { client in
      try await client.execute(uri: "/app/compressed", method: .get) { response in
        #expect(response.status == .ok)
        #expect(response.headers[.contentEncoding] == "gzip")
        #expect(Array(response.body.readableBytesView) == Self.opaqueBody)
      }
    }
  }

  @Test
  func `Forwarded headers replace the client's and identity encoding is asked for`() async throws {
    try await withProxiedUpstream { client in
      try await client.execute(
        uri: "/app/echo",
        method: .get,
        headers: [
          .acceptEncoding: "gzip, deflate",
          HTTPField.Name("X-Forwarded-Proto")!: "http"
        ]
      ) { response in
        let echoed = try JSONDecoder().decode(EchoedRequest.self, from: response.body)
        #expect(echoed.headers["accept-encoding"] == nil)
        #expect(echoed.headers["x-forwarded-proto"] == ["https"])
        #expect(echoed.headers["x-forwarded-prefix"] == ["/app"])
      }
    }
  }

  @Test
  func `A doubled leading slash still forwards the path after the route`() async throws {
    try await withProxiedUpstream { client in
      try await client.execute(uri: "//app/route/endpoint", method: .get) { response in
        #expect(response.status == .ok)
        let echoed = try JSONDecoder().decode(EchoedRequest.self, from: response.body)
        #expect(echoed.path == "/route/endpoint")
      }
    }
  }

  @Test
  func `An upstream with nothing listening answers as a bad gateway`() async throws {
    let multiplexer = try Multiplexer()
    try await multiplexer.registerRoute(
      name: "app",
      route: Self.route,
      upstream: URL(string: "http://127.0.0.1:1")!
    )

    try await multiplexer.buildIngressApplication()
      .test(.live) { client in
        try await client.execute(uri: "/app/", method: .get) { response in
          #expect(response.status == .badGateway)
          let error = try JSONDecoder().decode(MultiplexerErrorResponse.self, from: response.body)
          #expect(error == MultiplexerErrorResponse(error: "upstream_unavailable"))
        }
      }
  }

  /// Runs a real upstream on a kernel-assigned port, points a MUX route at it, and drives that
  /// MUX's ingress over a live connection: the client and the headers are then the ones a browser
  /// would produce rather than a router invocation's.
  private func withProxiedUpstream(
    _ body: @Sendable (any TestClientProtocol) async throws -> Void
  ) async throws {
    let upstreamPort = AsyncValue<Int>()
    let upstream = Self.upstreamApplication(reportingPortTo: upstreamPort)
    let multiplexer = Multiplexer(database: try TestDatabase.inMemory())

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        // The upstream is stopped by cancelling this task once the assertions are done.
        try? await upstream.runService()
      }
      let port = await upstreamPort.value
      try await multiplexer.registerRoute(
        name: "app",
        route: Self.route,
        upstream: URL(string: "http://127.0.0.1:\(port)")!
      )
      try await multiplexer.buildIngressApplication()
        .test(.live) { client in
          try await body(client)
        }
      group.cancelAll()
    }
    await multiplexer.captureRecorder.finish()
  }

  private static func upstreamApplication(
    reportingPortTo port: AsyncValue<Int>
  ) -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
    router.get("/redirect") { _, _ in
      Response(status: .found, headers: [.location: "/login"])
    }
    router.get("/compressed") { _, _ in
      Response(
        status: .ok,
        headers: [.contentEncoding: "gzip", .contentType: "application/octet-stream"],
        body: ResponseBody(byteBuffer: ByteBuffer(bytes: opaqueBody))
      )
    }
    router.get("/**") { request, _ in
      var headers: [String: [String]] = [:]
      for header in request.headers {
        headers[header.name.canonicalName, default: []].append(header.value)
      }
      return EchoedRequest(path: request.uri.path, headers: headers)
    }

    return Application(
      router: router,
      configuration: ApplicationConfiguration(
        address: .hostname("127.0.0.1", port: 0),
        serverName: "tailreg-mux-proxy-test-upstream"
      ),
      onServerRunning: { channel in
        port.fulfill(channel.localAddress?.port ?? 0)
      }
    )
  }
}
