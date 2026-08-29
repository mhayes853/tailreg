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
}
