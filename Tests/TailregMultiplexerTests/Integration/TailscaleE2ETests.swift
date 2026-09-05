import Foundation
import SQLiteData
import TailregCore
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite(
  .enabled(if: ProcessInfo.processInfo.environment["TAILREG_INTEGRATION"] == "1"),
  .serialized
)
struct `MUX Tailscale E2E tests` {
  private static let ingressPort = 19_100
  private static let tailnetPort = 8_443
  private static let captureAdminPort = 19_106

  private enum FixtureError: Error {
    case executableNotFound
    case failedToStart
  }

  private struct EndpointResponse: Decodable, Equatable {
    let binding: String
    let result: String
  }

  @Test
  func `Routes two dev servers through one physical Tailscale binding`() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tailreg-mux-e2e-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let databasePath = temporaryDirectory.appendingPathComponent("tailreg.sqlite").path
    let fixture = try startFixture(databasePath: databasePath)
    let binder = try TailscaleBinder.standard(
      databasePath: databasePath
    )

    do {
      try await waitForFixture()
      let tailscaleBinding = try await binder.bind(
        localPort: Self.ingressPort,
        to: TailscaleTailnetPort.explicit(Self.tailnetPort)
      )
      let tailnetURL = try #require(tailscaleBinding.url)
      let session = URLSession(configuration: URLSessionConfiguration.ephemeral)
      defer { session.invalidateAndCancel() }

      #expect(tailscaleBinding.localPort == Self.ingressPort)
      #expect(tailscaleBinding.mountPath == "/")

      for route in ["web-0", "web-1"] {
        let routeURL = tailnetURL.appendingPathComponent(route, isDirectory: true)
        let (data, response) = try await session.data(from: routeURL)
        let httpResponse = try #require(response as? HTTPURLResponse)

        #expect(httpResponse.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("<main id=app>\(route)</main>"))

        let endpointURL = tailnetURL.appendingPathComponent("route/endpoint")
        let (endpointData, endpointResponse) = try await session.data(from: endpointURL)
        let endpointHTTPResponse = try #require(endpointResponse as? HTTPURLResponse)
        let endpoint = try JSONDecoder().decode(EndpointResponse.self, from: endpointData)

        #expect(endpointHTTPResponse.statusCode == 200)
        #expect(endpoint == EndpointResponse(binding: route, result: "correct-upstream"))

        let captureURL = URL(
          string: "http://127.0.0.1:\(Self.captureAdminPort)/captures/\(route)"
        )!
        let (_, captureResponse) = try await session.data(from: captureURL)
        #expect((captureResponse as? HTTPURLResponse)?.statusCode == 200)
      }

      let captureDatabase = try openTailregDatabase(path: databasePath, kind: .queue)
      for route in ["web-0", "web-1"] {
        let paths: [String] = try await captureDatabase.read { db -> [String] in
          let routeRecord = try MuxRouteRecord.where { $0.route.eq(route) }.fetchOne(db)
          guard let routeRecord else { return [String]() }
          return try HTTPExchangeRecord.page(for: routeRecord.id, limit: 100)
            .fetchAll(db)
            .map(\.path)
        }
        #expect(paths.contains { $0.hasSuffix("/route/endpoint") })
      }

      _ = try await binder.unbind(tailnetPort: Self.tailnetPort)
      stopFixture(fixture)
    } catch {
      _ = try? await binder.unbind(tailnetPort: Self.tailnetPort)
      stopFixture(fixture)
      throw error
    }
  }

  private func startFixture(databasePath: String) throws -> Process {
    let testExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
    var searchDirectory = testExecutable.deletingLastPathComponent()
    var fixtureURL: URL?
    for _ in 0..<4 {
      let candidate = searchDirectory.appendingPathComponent("TailregMultiplexerE2EFixture")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        fixtureURL = candidate
        break
      }
      searchDirectory.deleteLastPathComponent()
    }
    guard let fixtureURL else { throw FixtureError.executableNotFound }

    let process = Process()
    process.executableURL = fixtureURL
    var environment = ProcessInfo.processInfo.environment
    environment["TAILREG_E2E_SECURE_COOKIES"] = "1"
    environment["TAILREG_E2E_DATABASE_PATH"] = databasePath
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }

  private func waitForFixture() async throws {
    let statusURL = URL(string: "http://127.0.0.1:\(Self.ingressPort)/__fixture_ready__")!
    for _ in 0..<100 {
      if let (_, response) = try? await URLSession.shared.data(from: statusURL),
        (response as? HTTPURLResponse)?.statusCode == 404
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw FixtureError.failedToStart
  }

  private func stopFixture(_ process: Process) {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }
}
