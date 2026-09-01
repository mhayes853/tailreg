import Foundation
import TailregCore

struct TailnetEndpointController: Sendable {
  let databasePath: String
  let localOnly: Bool
  let requestedPort: PortNumber?
  let environment: [String: String]

  func ensure(ingressPort: Int) async throws -> URL {
    if localOnly {
      return URL(string: "http://127.0.0.1:\(ingressPort)/")!
    }

    let binder = try makeBinder()
    if let url = try await binder.bindings()
      .first(where: { binding in
        binding.localPort == ingressPort && binding.mountPath == "/"
          && (requestedPort.map { $0.intValue == binding.tailnetPort } ?? true)
      })?
      .url
    {
      return url
    }

    let binding = try await binder.bind(
      localPort: ingressPort,
      to: requestedPort.map { .explicit($0.intValue) } ?? .auto,
      mountPath: "/"
    )
    guard let url = binding.url else { throw ProjectEndpointError() }
    return url
  }

  func remove(ingressPort: Int) async throws {
    guard !localOnly else { return }
    let binder = try makeBinder()
    _ = try await binder.unbind(localPort: ingressPort)
  }

  private func makeBinder() throws -> TailscaleBinder {
    let searchPaths =
      environment["TAILREG_TAILSCALE_PATH"].map { [$0] }
      ?? TailscaleLocator.defaultSearchPaths(environment: environment)
    return try TailscaleBinder.standard(
      searchPaths: searchPaths,
      databasePath: databasePath
    )
  }
}

struct ProjectEndpointError: Error, CustomStringConvertible {
  let description = "Tailscale did not report a public URL for the project MUX"
}
