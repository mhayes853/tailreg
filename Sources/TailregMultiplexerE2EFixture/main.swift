import Foundation
import Hummingbird
import TailregMultiplexer

private struct FixtureEndpointResponse: ResponseCodable {
  let binding: String
  let result: String
}

@main
enum TailregMultiplexerE2EFixture {
  static func main() async throws {
    let firstUpstreamPort = 19_101
    let secondUpstreamPort = 19_102
    let ingressPort = 19_100
    let secureCookies = ProcessInfo.processInfo.environment["TAILREG_E2E_SECURE_COOKIES"] == "1"
    let routingCookieName = secureCookies ? "__Host-tailreg-route" : "tailreg-route"

    let firstUpstream = upstreamApplication(
      binding: "web-0",
      port: firstUpstreamPort
    )
    let secondUpstream = upstreamApplication(
      binding: "web-1",
      port: secondUpstreamPort
    )

    let registry = BindingRegistry()
    let firstBinding = try await registry.register(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:\(firstUpstreamPort)")!
    )
    let secondBinding = try await registry.register(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:\(secondUpstreamPort)")!
    )
    precondition(firstBinding.route == "web-0")
    precondition(secondBinding.route == "web-1")

    let multiplexer = Multiplexer(
      configuration: Multiplexer.Configuration(
        ingressPort: ingressPort,
        routingCookieName: routingCookieName,
        secureCookies: secureCookies
      ),
      registry: registry
    )
    let ingress = Application(
      responder: MuxIngressResponder(
        registry: registry,
        cookieName: multiplexer.configuration.routingCookieName,
        secureCookies: multiplexer.configuration.secureCookies
      ),
      configuration: ApplicationConfiguration(
        address: .hostname("127.0.0.1", port: ingressPort),
        serverName: "tailreg-mux-ingress"
      ),
      services: [firstUpstream, secondUpstream]
    )
    try await ingress.runService()
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

    return Application(
      router: router,
      configuration: ApplicationConfiguration(
        address: .hostname("127.0.0.1", port: port),
        serverName: "tailreg-mux-e2e-upstream-\(binding)"
      )
    )
  }
}
