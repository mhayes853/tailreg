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
    let ingressPort = PortNumber(rawValue: 19_100)!
    let publicScheme: PublicScheme =
      ProcessInfo.processInfo.environment["TAILREG_E2E_SECURE_COOKIES"] == "1" ? .https : .http
    let routingCookieName = publicScheme == .https ? "__Host-tailreg-route" : "tailreg-route"
    let databasePath =
      ProcessInfo.processInfo.environment["TAILREG_E2E_DATABASE_PATH"] ?? ":memory:"
    let database = try openTailregDatabase(path: databasePath, kind: .queue)

    let firstUpstream = upstreamApplication(binding: "web-0", port: firstUpstreamPort)
    let secondUpstream = upstreamApplication(binding: "web-1", port: secondUpstreamPort)

    let multiplexer = Multiplexer(
      configuration: Multiplexer.Configuration(
        ingressPort: ingressPort,
        unmatchedPathPolicy: .lastSelectedRouteCompatibility,
        routingCookieName: routingCookieName,
        publicScheme: publicScheme
      ),
      database: database
    )
    for (name, port, route) in [
      ("web", firstUpstreamPort, "web-0"),
      ("web", secondUpstreamPort, "web-1"),
      ("sveltekit", svelteKitUpstreamPort, "sveltekit-0"),
      ("nextjs", nextJSUpstreamPort, "nextjs-0"),
      ("nuxt", nuxtUpstreamPort, "nuxt-0"),
      ("astro", astroUpstreamPort, "astro-0"),
      ("tanstack-start", tanStackStartUpstreamPort, "tanstack-start-0")
    ] {
      let binding = try await multiplexer.registerRoute(
        name: name,
        upstream: URL(string: "http://127.0.0.1:\(port)")!
      )
      precondition(binding.route.rawValue == route)
    }
    let fullStackFrontend = try await multiplexer.registerRoute(
      name: "Storefront",
      route: MuxRouteName(rawValue: "web")!,
      upstream: URL(string: "http://127.0.0.1:19109")!
    )
    let fullStackBackend = try await multiplexer.registerRoute(
      name: "Storefront API",
      route: MuxRouteName(rawValue: "api")!,
      upstream: URL(string: "http://127.0.0.1:19110")!
    )
    precondition(fullStackFrontend.route.rawValue == "web")
    precondition(fullStackBackend.route.rawValue == "api")

    let captureAdmin = captureApplication(
      database: database,
      recorder: multiplexer.captureRecorder,
      port: captureAdminPort
    )
    let ingress = multiplexer.buildIngressApplication(
      services: [firstUpstream, secondUpstream, captureAdmin]
    )
    try await ingress.runService()
  }
}
