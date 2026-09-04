import Foundation
import TailregCore

/// Removes a project's shared runtime once nothing is routed through it.
///
/// The MUX and the root Tailscale binding exist to serve routes, so they are torn down when the
/// last route goes and not before. Both `up` and `down` reach this point — `up` when its final
/// managed application exits, `down` when it has stopped everything it was asked to — and running
/// two different versions of that reasoning is how a MUX or a binding gets leaked.
///
/// This deliberately does **not** take the runtime lock. `FileLock` is not reentrant: a second
/// acquisition in the same process polls until it times out rather than deadlocking, and `down`
/// already holds the lock across its whole reconciliation. Callers lock.
struct ProjectRuntimeTeardown: Sendable {
  let admin: MuxAdminClient
  let muxController: MuxProcessController
  let endpointController: TailnetEndpointController

  enum Outcome: Equatable, Sendable {
    /// Routes remain, so the runtime is still needed.
    case stillInUse(routes: Int)
    case stopped
    /// The runtime could not be fully removed. The project may still be reachable.
    case failed(String)
  }

  func stopIfUnused(_ runtime: MuxRunRecord) async -> Outcome {
    // An unreachable MUX serves nothing, so it is treated as having no routes. Refusing to
    // proceed here would leave a half-dead runtime that nothing is ever able to clean up.
    let live = (try? await admin.routes()) ?? []
    guard live.isEmpty else { return .stillInUse(routes: live.count) }

    // Whether Tailscale is involved follows what the runtime recorded, not what this invocation
    // was told. A local runtime has no binding to remove, and asking Tailscale about one would
    // make stopping it depend on a daemon it never needed.
    if runtime.exposure == .tailnet {
      do {
        try await endpointController.remove(ingressPort: runtime.ingressPort)
      } catch {
        return .failed("the Tailscale binding could not be removed: \(error)")
      }
    }
    do {
      _ = try await muxController.stop(runtime)
    } catch {
      return .failed("the project MUX could not be stopped: \(error)")
    }
    return .stopped
  }
}
