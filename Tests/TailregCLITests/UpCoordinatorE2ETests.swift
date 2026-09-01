import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import Testing

@testable import TailregCLI

@Suite(.serialized, .timeLimit(.minutes(1)))
struct `Up coordinator E2E tests` {
  @Test
  func `Brings up a configured frontend and API through one project MUX`() async throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixture = packageRoot.appendingPathComponent("Tests/Fixtures/FullStack")
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
      .deletingLastPathComponent()
      .appendingPathComponent("tailreg")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))

    let stateDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tailreg-cli-e2e-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stateDirectory) }

    let observation = ReadyObservation()
    var environment = ProcessInfo.processInfo.environment
    environment["TAILREG_E2E_AUTO_EXIT_MS"] = "2500"
    environment["TAILREG_STARTUP_TIMEOUT_MS"] = "15000"
    let coordinator = UpCoordinator(
      databasePath: stateDirectory.appendingPathComponent("tailreg.sqlite").path,
      executableURL: executable,
      environment: environment,
      currentDirectory: fixture
    )

    let result = try await coordinator.run(
      UpRequest(projectPath: fixture.path, localOnly: true)
    ) { ready in
      await observation.probe(ready)
    }

    #expect(result.projectName == "storefront")
    #expect(Set(result.applications.compactMap(\.route)) == ["api", "web"])
    let outcome = await observation.outcome
    #expect(outcome == .success)
  }
}

private actor ReadyObservation {
  enum Outcome: Equatable {
    case notRun
    case success
    case failure(String)
  }

  private(set) var outcome = Outcome.notRun

  func probe(_ result: UpResult) async {
    do {
      guard
        let web = result.applications.first(where: { $0.name == "web" })?.publicURL,
        let api = result.applications.first(where: { $0.name == "api" })?.publicURL
      else {
        outcome = .failure("ready result did not contain web and api URLs")
        return
      }
      let (webData, webResponse) = try await URLSession.shared.data(from: web)
      let assetURL = result.baseURL.appendingPathComponent("assets/app.js")
      var assetRequest = URLRequest(url: assetURL)
      if let setCookie = (webResponse as? HTTPURLResponse)?
        .value(forHTTPHeaderField: "Set-Cookie")?
        .split(separator: ";").first
      {
        assetRequest.setValue(String(setCookie), forHTTPHeaderField: "Cookie")
      }
      let (assetData, assetResponse) = try await URLSession.shared.data(for: assetRequest)
      let productsURL = api.appendingPathComponent("products")
      let (apiData, apiResponse) = try await URLSession.shared.data(from: productsURL)
      guard (webResponse as? HTTPURLResponse)?.statusCode == 200,
        String(decoding: webData, as: UTF8.self).contains("<h1>Storefront</h1>"),
        (assetResponse as? HTTPURLResponse)?.statusCode == 200,
        String(decoding: assetData, as: UTF8.self).contains("document.body.dataset.assets"),
        (apiResponse as? HTTPURLResponse)?.statusCode == 200,
        String(decoding: apiData, as: UTF8.self).contains("Keyboard")
      else {
        outcome = .failure("the frontend or API returned unexpected content")
        return
      }
      outcome = .success
    } catch {
      outcome = .failure(String(describing: error))
    }
  }
}
