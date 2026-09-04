import Foundation
import TailregCore
import UUIDV7

/// Where a project is reachable, and the binding record a run holds to keep it that way.
struct TailnetEndpoint: Sendable {
  let url: URL
  /// Nil for a local runtime, and for a live serve that Tailreg did not record itself.
  let bindingID: UUIDV7?
}

/// The half of endpoint control that teardown needs, so it can be driven without Tailscale.
protocol TailnetEndpointRemoving: Sendable {
  func remove(_ binding: TailscaleBindingRecord) async throws
}

/// Publishes a project MUX on the tailnet, and takes it back down.
struct TailnetEndpointController: TailnetEndpointRemoving {
  let databasePath: String
  let environment: [String: String]

  /// Returns where the project is reachable, binding it to the tailnet first when asked to.
  ///
  /// A project may hold more than one root binding: asking for a tailnet port that differs from
  /// an existing binding's adds one rather than moving it, and each run holds exactly the
  /// binding it asked for.
  func ensure(
    ingressPort: Int,
    exposure: ProjectExposure,
    requestedPort: PortNumber? = nil
  ) async throws -> TailnetEndpoint {
    if exposure == .local {
      return TailnetEndpoint(url: URL(string: "http://127.0.0.1:\(ingressPort)/")!, bindingID: nil)
    }

    let binder = try makeBinder()
    let existing = try await binder.bindings()
      .first { binding in
        binding.localPort == ingressPort && binding.mountPath == "/"
          && (requestedPort.map { $0.intValue == binding.tailnetPort } ?? true)
      }
    let binding: TailscaleBinding
    if let existing {
      binding = existing
    } else {
      binding = try await binder.bind(
        localPort: ingressPort,
        to: requestedPort.map { .explicit($0.intValue) } ?? .auto,
        mountPath: "/"
      )
    }
    guard let url = binding.url else { throw ProjectEndpointError() }
    return TailnetEndpoint(url: url, bindingID: binding.recordID)
  }

  func remove(_ binding: TailscaleBindingRecord) async throws {
    let binder = try makeBinder()
    _ = try await binder.unbind(tailnetPort: binding.tailnetPort, mountPath: binding.mountPath)
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
