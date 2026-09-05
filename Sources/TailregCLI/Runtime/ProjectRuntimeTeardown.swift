import Foundation
import SQLiteData
import TailregCore

/// Removes a project's shared runtime once nothing is routed through it, and its root bindings
/// once nothing holds them.
///
/// The MUX exists to serve routes, so it is torn down when the last route goes and not before.
/// A root binding exists to publish the runs that asked for it, and every live run records the
/// binding it holds, so a binding is unbound when no live run references it. Neither is a
/// counter: the live rows *are* the references, and a supervisor that dies mid-teardown leaves a
/// row that the next reconciliation can see, rather than a number that is off by one.
///
/// Both `up` and `down` reach this point — `up` when its final managed application exits, `down`
/// when it has stopped everything it was asked to — and running two different versions of that
/// reasoning is how a MUX or a binding gets leaked.
///
/// This deliberately does **not** take the runtime lock. `FileLock` is not reentrant: a second
/// acquisition in the same process polls until it times out rather than deadlocking, and `down`
/// already holds the lock across its whole reconciliation. Callers lock.
struct ProjectRuntimeTeardown: Sendable {
  let liveRouteCount: @Sendable () async throws -> Int
  let muxController: MuxProcessController
  let endpointController: any TailnetEndpointRemoving

  enum Outcome: Equatable, Sendable {
    /// Routes remain, so the runtime is still needed.
    case stillInUse(routes: Int)
    case stopped
    /// The runtime could not be fully removed. The project may still be reachable.
    case failed(String)
  }

  /// What happened to one root binding.
  enum BindingOutcome: Equatable, Sendable {
    /// Nothing held it any more.
    case removed(TailscaleBindingRecord)
    /// Live runs still hold it, so it stays. Named so `down` can say who.
    case retained(TailscaleBindingRecord, holders: [String])
    /// Removed on request while live runs still held it.
    case forced(TailscaleBindingRecord, holders: [String])
    case failed(TailscaleBindingRecord, String)

    var isFailure: Bool {
      if case .failed = self { return true }
      return false
    }
  }

  struct Result: Equatable, Sendable {
    let runtime: Outcome
    let bindings: [BindingOutcome]
  }

  /// - Parameter unbindingAll: Remove every root binding even if live runs still hold it.
  func stopIfUnused(_ runtime: MuxRunRecord, unbindingAll: Bool = false) async -> Result {
    // An unreachable MUX serves nothing, so it is treated as having no routes. Refusing to
    // proceed here would leave a half-dead runtime that nothing is ever able to clean up.
    let routes = (try? await liveRouteCount()) ?? 0

    // With the MUX going, a binding would point at nothing, so every one goes with it.
    let bindings: [BindingOutcome]
    do {
      bindings = try await releaseBindings(of: runtime, unbindingAll: unbindingAll || routes == 0)
    } catch {
      return Result(
        runtime: .failed("the project's bindings could not be read: \(error)"),
        bindings: []
      )
    }

    guard routes == 0 else {
      return Result(runtime: .stillInUse(routes: routes), bindings: bindings)
    }
    if bindings.contains(where: \.isFailure) {
      return Result(
        runtime: .failed("a Tailscale binding could not be removed"),
        bindings: bindings
      )
    }
    do {
      _ = try await muxController.stop(runtime)
    } catch {
      return Result(
        runtime: .failed("the project MUX could not be stopped: \(error)"),
        bindings: bindings
      )
    }
    return Result(runtime: .stopped, bindings: bindings)
  }

  /// Unbinds each root binding that no live run holds, and reports the holders of the rest.
  private func releaseBindings(
    of runtime: MuxRunRecord,
    unbindingAll: Bool
  ) async throws -> [BindingOutcome] {
    guard runtime.exposure == .tailnet else { return [] }
    let projectID = runtime.projectID
    let ingressPort = runtime.ingressPort
    let (bindings, runs) = try await muxController.database.read { database in
      (
        try TailscaleBindingRecord.live(localPort: ingressPort).fetchAll(database),
        try AppRunRecord.live(for: projectID).fetchAll(database)
      )
    }

    var outcomes: [BindingOutcome] = []
    for binding in bindings {
      let holders = runs.filter { $0.bindingID == binding.id }.map(\.name).sorted()
      guard holders.isEmpty || unbindingAll else {
        outcomes.append(.retained(binding, holders: holders))
        continue
      }
      do {
        try await endpointController.remove(binding)
        outcomes.append(holders.isEmpty ? .removed(binding) : .forced(binding, holders: holders))
      } catch {
        outcomes.append(.failed(binding, "\(error)"))
      }
    }
    return outcomes
  }
}
