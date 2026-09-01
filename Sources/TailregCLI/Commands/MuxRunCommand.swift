import ArgumentParser
import Foundation
import TailregCore
import TailregMultiplexer
import UUIDV7

struct MuxRunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_mux-run",
    abstract: "Run one project MUX.",
    shouldDisplay: false
  )

  @Option(name: .long) var databasePath: String
  @Option(name: .long) var muxID: String
  @Option(name: .long) var ingressPort: Int
  @Option(name: .long) var adminPort: Int
  @Flag(name: .long) var insecureCookies = false

  mutating func run() async throws {
    guard let id = UUIDV7(uuidString: muxID) else {
      throw ValidationError("invalid MUX ID")
    }
    let database = try openTailregDatabase(path: databasePath)
    let multiplexer = Multiplexer(
      configuration: Multiplexer.Configuration(
        adminPort: adminPort,
        id: id,
        ingressPort: ingressPort,
        unmatchedPathPolicy: .lastSelectedRouteCompatibility,
        routingCookieName: insecureCookies
          ? "tailreg-route-\(id.uuidString.lowercased())"
          : nil,
        secureCookies: !insecureCookies
      ),
      database: database
    )
    try await multiplexer.run()
  }
}
