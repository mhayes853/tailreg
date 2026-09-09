import Foundation
import Operation
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
    ingressPort: PortNumber,
    exposure: ProjectExposure,
    requestedPort: PortNumber? = nil
  ) async throws -> TailnetEndpoint {
    try await #run(
      $ensureEndpoint(ingressPort: ingressPort, exposure: exposure, requestedPort: requestedPort)
    )
  }

  @OperationRequest
  private func ensureEndpoint(
    ingressPort: PortNumber,
    exposure: ProjectExposure,
    requestedPort: PortNumber?
  ) async throws -> TailnetEndpoint {
    if exposure == .local {
      return TailnetEndpoint(url: .muxIngress(port: ingressPort), bindingID: nil)
    }

    let binder = try makeBinder()
    let existing = try await binder.bindings()
      .first { binding in
        binding.localPort == ingressPort && binding.mountPath == "/"
          && (requestedPort.map { $0 == binding.tailnetPort } ?? true)
      }
    let binding: TailscaleBinding
    if let existing {
      binding = existing
    } else {
      binding = try await binder.bind(
        localPort: ingressPort,
        to: requestedPort.map { .explicit($0) } ?? .auto,
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

extension URL {
  /// Where a project's MUX ingress answers on this machine.
  ///
  /// `up` returns it as the base URL of a `--local-only` runtime and `status` reports the same
  /// address for one, so the two agree by construction rather than by both being written out.
  static func muxIngress(port: PortNumber) -> URL {
    URL(string: "http://127.0.0.1:\(port)/")!
  }
}

struct ProjectEndpointError: Error, CustomStringConvertible {
  let description = "Tailscale did not report a public URL for the project MUX"
}
