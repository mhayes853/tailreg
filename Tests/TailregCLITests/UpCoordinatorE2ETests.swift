import Foundation
import Testing

@testable import TailregCLI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite(.serialized, .timeLimit(.minutes(1)))
struct `Up coordinator E2E tests` {
  @Test
  func `Brings up a configured frontend and API through one project MUX`() async throws {
    // The fixture servers exit on their own, so the supervisor this drives finishes rather than
    // running for the length of the suite.
    let project = try E2EProject(
      fixture: "FullStack",
      environment: ["TAILREG_E2E_AUTO_EXIT_MS": "2500"]
    )
    defer { project.cleanUp() }
    #expect(FileManager.default.isExecutableFile(atPath: project.executable.path))

    let observation = ReadyObservation()
    let result = try await project.up { ready in await observation.probe(ready) }

    #expect(result.projectName == "storefront")
    #expect(Set(result.applications.compactMap { $0.route?.rawValue }) == ["api", "web"])
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
