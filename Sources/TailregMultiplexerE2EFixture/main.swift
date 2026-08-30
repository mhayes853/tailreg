import Foundation
import Hummingbird
import SQLiteData
import TailregCore
import TailregMultiplexer

private struct FixtureEndpointResponse: ResponseCodable {
  let binding: String
  let result: String
}

private struct FixtureCapturedExchange: Codable, Sendable {
  let method: String
  let path: String
  let statusCode: Int?
  let outcome: String
  let requestBody: String?
  let requestBodyOmitted: Bool?
  let responseBody: String?
  let responseBodyOmitted: Bool?
}

private struct FixtureCaptureResponse: ResponseCodable {
  let route: String
  let exchanges: [FixtureCapturedExchange]
}

@main
enum TailregMultiplexerE2EFixture {
  static func main() async throws {
    let firstUpstreamPort = 19_101
    let secondUpstreamPort = 19_102
    let svelteKitUpstreamPort = 19_103
    let nextJSUpstreamPort = 19_104
    let nuxtUpstreamPort = 19_105
    let captureAdminPort = 19_106
    let ingressPort = 19_100
    let secureCookies = ProcessInfo.processInfo.environment["TAILREG_E2E_SECURE_COOKIES"] == "1"
    let routingCookieName = secureCookies ? "__Host-tailreg-route" : "tailreg-route"
    let databasePath =
      ProcessInfo.processInfo.environment["TAILREG_E2E_DATABASE_PATH"] ?? ":memory:"
    let database = try openTailregDatabase(path: databasePath, kind: .queue)

    let firstUpstream = upstreamApplication(
      binding: "web-0",
      port: firstUpstreamPort
    )
    let secondUpstream = upstreamApplication(
      binding: "web-1",
      port: secondUpstreamPort
    )

    let multiplexer = Multiplexer(
      configuration: Multiplexer.Configuration(
        ingressPort: ingressPort,
        routingCookieName: routingCookieName,
        secureCookies: secureCookies
      ),
      database: database
    )
    let registry = multiplexer.registry
    let firstBinding = try await registry.register(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:\(firstUpstreamPort)")!
    )
    let secondBinding = try await registry.register(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:\(secondUpstreamPort)")!
    )
    let svelteKitBinding = try await registry.register(
      name: "sveltekit",
      upstream: URL(string: "http://127.0.0.1:\(svelteKitUpstreamPort)")!
    )
    let nextJSBinding = try await registry.register(
      name: "nextjs",
      upstream: URL(string: "http://127.0.0.1:\(nextJSUpstreamPort)")!
    )
    let nuxtBinding = try await registry.register(
      name: "nuxt",
      upstream: URL(string: "http://127.0.0.1:\(nuxtUpstreamPort)")!
    )
    precondition(firstBinding.route == "web-0")
    precondition(secondBinding.route == "web-1")
    precondition(svelteKitBinding.route == "sveltekit-0")
    precondition(nextJSBinding.route == "nextjs-0")
    precondition(nuxtBinding.route == "nuxt-0")

    guard let captureRecorder = multiplexer.captureRecorder else {
      preconditionFailure("The E2E fixture requires capture storage")
    }
    let captureAdmin = captureApplication(
      database: database,
      recorder: captureRecorder,
      port: captureAdminPort
    )

    let ingress = Application(
      responder: MuxIngressResponder(
        registry: registry,
        cookieName: multiplexer.configuration.routingCookieName,
        secureCookies: multiplexer.configuration.secureCookies,
        capturedHeaderPolicy: multiplexer.configuration.capturedHeaderPolicy,
        captureRecorder: multiplexer.captureRecorder
      ),
      configuration: ApplicationConfiguration(
        address: .hostname("127.0.0.1", port: ingressPort),
        serverName: "tailreg-mux-ingress"
      ),
      services: [firstUpstream, secondUpstream, captureAdmin]
    )
    try await ingress.runService()
  }

  private static func captureApplication(
    database: any DatabaseWriter,
    recorder: CaptureRecorder,
    port: Int
  ) -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
    router.get("/captures/:route") { _, context in
      let route = try context.parameters.require("route")
      await recorder.flush()

      return try await database.read { db in
        let fetchedRoute =
          try MuxRouteRecord
          .where { $0.route.eq(route) && $0.endedAt.is(nil) }
          .fetchOne(db)
        guard let routeRecord = fetchedRoute else { throw HTTPError(.notFound) }
        let exchanges = try HTTPExchangeRecord.page(for: routeRecord.id, limit: 1_000).fetchAll(db)
        let bodies =
          try HTTPExchangeBodyRecord
          .where { $0.exchangeID.in(exchanges.map(\.id)) }
          .fetchAll(db)
        let requestBodiesByExchange = Dictionary(
          uniqueKeysWithValues: bodies.filter { $0.direction == .request }
            .map {
              ($0.exchangeID, $0)
            }
        )
        let responseBodiesByExchange = Dictionary(
          uniqueKeysWithValues: bodies.filter { $0.direction == .response }
            .map {
              ($0.exchangeID, $0)
            }
        )
        return FixtureCaptureResponse(
          route: route,
          exchanges: exchanges.map { exchange in
            let requestBody = requestBodiesByExchange[exchange.id]
            let responseBody = responseBodiesByExchange[exchange.id]
            return FixtureCapturedExchange(
              method: exchange.method,
              path: exchange.path,
              statusCode: exchange.statusCode,
              outcome: exchange.outcome.rawValue,
              requestBody: requestBody?.content.map { String(decoding: $0, as: UTF8.self) },
              requestBodyOmitted: requestBody?.omitted,
              responseBody: responseBody?.content.map { String(decoding: $0, as: UTF8.self) },
              responseBodyOmitted: responseBody?.omitted
            )
          }
        )
      }
    }

    return Application(
      router: router,
      configuration: ApplicationConfiguration(
        address: .hostname("127.0.0.1", port: port),
        serverName: "tailreg-mux-e2e-capture-admin"
      )
    )
  }

  private static func upstreamApplication(
    binding: String,
    port: Int
  ) -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
    router.get("/") { _, _ in
      Response(
        status: .ok,
        headers: [.contentType: "text/html; charset=utf-8"],
        body: ResponseBody(
          byteBuffer: ByteBuffer(
            string: "<!doctype html><title>Tailreg fixture</title><main id=app>\(binding)</main>"
          )
        )
      )
    }
    router.get("/route/endpoint") { _, _ in
      FixtureEndpointResponse(binding: binding, result: "correct-upstream")
    }
    router.post("/echo") { request, _ in
      let body = try await request.body.collect(upTo: 1_048_576)
      return Response(
        status: .ok,
        headers: [.contentType: request.headers[.contentType] ?? "application/octet-stream"],
        body: ResponseBody(byteBuffer: body)
      )
    }

    return Application(
      router: router,
      configuration: ApplicationConfiguration(
        address: .hostname("127.0.0.1", port: port),
        serverName: "tailreg-mux-e2e-upstream-\(binding)"
      )
    )
  }
}
