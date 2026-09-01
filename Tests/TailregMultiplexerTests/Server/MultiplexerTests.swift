import Foundation
import Hummingbird
import HummingbirdTesting
import TailregMultiplexer
import Testing

@Suite
struct `Multiplexer tests` {
  @Test
  func `Status reports that the multiplexer is available`() async throws {
    let application = Multiplexer().buildApplication()

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
    let application = Multiplexer().buildApplication()

    try await application.test(.router) { client in
      try await client.execute(uri: "/unknown", method: .get) { response in
        #expect(response.status == .notFound)
      }
    }
  }

  @Test
  func `Public status is available without a binding`() async throws {
    let application = Multiplexer().buildIngressApplication()

    try await application.test(.router) { client in
      try await client.execute(uri: "/_tailreg/status", method: .get) { response in
        #expect(response.status == .ok)
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
  func `Unresolved public routes return a diagnostic response`() async throws {
    let application = Multiplexer().buildIngressApplication()

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
    let registry = BindingRegistry()
    _ = try await registry.register(name: "web", upstream: URL(string: "http://127.0.0.1:1")!)
    let application = Multiplexer(registry: registry).buildIngressApplication()

    try await application.test(.router) { client in
      try await client.execute(uri: "/web-0?preview=true", method: .get) { response in
        #expect(response.status == .temporaryRedirect)
        #expect(response.headers[.location] == "/web-0/?preview=true")
      }
    }
  }
}
