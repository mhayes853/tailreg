import Foundation
import Hummingbird
import TailregCore
import TailregMultiplexer

@main
enum TailregMultiplexerE2EFixture {
  static func main() async throws {
    let firstUpstreamPort = 19_101
    let secondUpstreamPort = 19_102
    let svelteKitUpstreamPort = 19_103
    let nextJSUpstreamPort = 19_104
    let nuxtUpstreamPort = 19_105
    let captureAdminPort = 19_106
    let astroUpstreamPort = 19_107
    let tanStackStartUpstreamPort = 19_108
    let ingressPort = 19_100
    let secureCookies = ProcessInfo.processInfo.environment["TAILREG_E2E_SECURE_COOKIES"] == "1"
    let routingCookieName = secureCookies ? "__Host-tailreg-route" : "tailreg-route"
    let databasePath =
      ProcessInfo.processInfo.environment["TAILREG_E2E_DATABASE_PATH"] ?? ":memory:"
    let database = try openTailregDatabase(path: databasePath, kind: .queue)

    let firstUpstream = upstreamApplication(binding: "web-0", port: firstUpstreamPort)
    let secondUpstream = upstreamApplication(binding: "web-1", port: secondUpstreamPort)

    let multiplexer = Multiplexer(
      configuration: Multiplexer.Configuration(
        ingressPort: ingressPort,
        routingCookieName: routingCookieName,
        secureCookies: secureCookies
      ),
      database: database
    )
    let registry = multiplexer.registry
    for (name, port, route) in [
      ("web", firstUpstreamPort, "web-0"),
      ("web", secondUpstreamPort, "web-1"),
      ("sveltekit", svelteKitUpstreamPort, "sveltekit-0"),
      ("nextjs", nextJSUpstreamPort, "nextjs-0"),
      ("nuxt", nuxtUpstreamPort, "nuxt-0"),
      ("astro", astroUpstreamPort, "astro-0"),
      ("tanstack-start", tanStackStartUpstreamPort, "tanstack-start-0")
    ] {
      let binding = try await registry.register(
        name: name,
        upstream: URL(string: "http://127.0.0.1:\(port)")!
      )
      precondition(binding.route == route)
    }

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
}
