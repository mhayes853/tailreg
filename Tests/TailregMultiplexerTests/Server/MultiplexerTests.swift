import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import TailregMultiplexer
import Testing
import UUIDV7

@Suite
struct `Multiplexer tests` {
  @Test
  func `Compatibility cookies are scoped to the MUX instance`() {
    let firstID = UUIDV7()
    let secondID = UUIDV7()

    let first = Multiplexer.Configuration(id: firstID)
    let second = Multiplexer.Configuration(id: secondID)

    #expect(first.routingCookieName != second.routingCookieName)
    #expect(first.routingCookieName.hasPrefix("__Host-tailreg-route-"))
  }

  @Test
  func `Status reports that the multiplexer is available`() async throws {
    let application = try Multiplexer().buildApplication()

    try await application.test(.router) { client in
      try await client.execute(uri: "/status", method: .get) { response in
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/json; charset=utf-8")

        let status = try JSONDecoder()
          .decode(
            MultiplexerStatus.self,
            from: Data(response.body.readableBytesView)
          )
        #expect(status == MultiplexerStatus(status: "ok"))
      }
    }
  }

  @Test
  func `Unknown admin routes are not found`() async throws {
    let application = try Multiplexer().buildApplication()

    try await application.test(.router) { client in
      try await client.execute(uri: "/unknown", method: .get) { response in
        #expect(response.status == .notFound)
      }
    }
  }

  @Test
  func `Admin API attaches and removes routes from a running MUX`() async throws {
    let multiplexer = try Multiplexer()
    let application = multiplexer.buildApplication()
    let registration = MuxRouteRegistrationRequest(
      name: "Web App",
      upstreamURL: "http://127.0.0.1:3000"
    )
    let body = try JSONEncoder().encode(registration)

    try await application.test(.router) { client in
      try await client.execute(
        uri: "/routes",
        method: .post,
        headers: [.contentType: "application/json"],
        body: ByteBuffer(data: body)
      ) { response in
        #expect(response.status == .ok)
        let route = try JSONDecoder().decode(MuxRouteResponse.self, from: response.body)
        #expect(route.route == "web-app-0")
        #expect(route.publicPath == "/web-app-0/")
      }

      try await client.execute(uri: "/routes", method: .get) { response in
        let routes = try JSONDecoder().decode([MuxRouteResponse].self, from: response.body)
        #expect(routes.map(\.route) == ["web-app-0"])
      }

      let update = try JSONEncoder()
        .encode(
          MuxRouteUpdateRequest(
            upstreamURL: "http://127.0.0.1:4000",
            pathMode: .preserveRoutePrefix
          )
        )
      try await client.execute(
        uri: "/routes/web-app-0",
        method: .put,
        headers: [.contentType: "application/json"],
        body: ByteBuffer(data: update)
      ) { response in
        let route = try JSONDecoder().decode(MuxRouteResponse.self, from: response.body)
        #expect(route.upstreamURL == "http://127.0.0.1:4000")
        #expect(route.pathMode == .preserveRoutePrefix)
      }

      try await client.execute(uri: "/routes/web-app-0", method: .delete) { response in
        #expect(response.status == .noContent)
      }
    }

    #expect(try await multiplexer.routes().isEmpty)
  }

  @Test
  func `Public ingress does not reserve a status route`() async throws {
    let application = try Multiplexer().buildIngressApplication()

    try await application.test(.router) { client in
      try await client.execute(uri: "/_tailreg/status", method: .get) { response in
        #expect(response.status == .notFound)
      }
    }
  }

  @Test
  func `Unresolved public routes return a diagnostic response`() async throws {
    let application = try Multiplexer().buildIngressApplication()

    try await application.test(.router) { client in
      try await client.execute(uri: "/api/route", method: .get) { response in
        #expect(response.status == .notFound)
        let error = try JSONDecoder()
          .decode(
            MultiplexerErrorResponse.self,
            from: Data(response.body.readableBytesView)
          )
        #expect(
          error
            == MultiplexerErrorResponse(
              error: "route_not_resolved",
              message: "Open a generated Tailreg URL first."
            )
        )
      }
    }
  }

  @Test
  func `A generated route without its trailing slash is canonicalized`() async throws {
    let multiplexer = try Multiplexer()
    _ = try await multiplexer.registerRoute(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:1")!
    )
    let application = multiplexer.buildIngressApplication()

    try await application.test(.router) { client in
      try await client.execute(uri: "/web-0?preview=true", method: .get) { response in
        #expect(response.status == .temporaryRedirect)
        #expect(response.headers[.location] == "/web-0/?preview=true")
      }
    }
  }

}
