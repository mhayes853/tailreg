import Foundation
import TailregCore
import Testing

@testable import TailregCLI

/// These drive `down` against a real project MUX, which is the half of it that the record-level
/// suite cannot reach: removing a route from a multiplexer that is serving it, and tearing the
/// runtime down once the last route is gone.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct `Down coordinator E2E tests` {
  /// Attached applications leave no supervisor running, so nothing else is racing `down` to end
  /// the runs. What `down` reports here is exactly what `down` did.
  @Test
  func `A route is removed from the running MUX and the last one takes the project with it`()
    async throws
  {
    let project = try E2EProject(fixture: "Teardown")
    defer { project.cleanUp() }
    let apiUpstream = try project.startUpstream(port: 19_112)
    let webUpstream = try project.startUpstream(port: 19_111)
    let apiURL = try await project.attach("api", to: 19_112)
    let webURL = try await project.attach("web", to: 19_111)

    let runtime = try #require(try await project.runtime())
    let admin = MuxAdminClient(port: runtime.adminPort)
    let published = try await admin.routes().map(\.route.rawValue).sorted()
    #expect(published == ["api", "web"])
    #expect(await project.responseStatus(of: webURL) == 200)

    let partial = try await project.down(["web"])

    #expect(partial.applications.map(\.name) == ["web"])
    #expect(partial.applications.first?.outcome == .detached)
    #expect(partial.runtime == .stillInUse(routes: 1))
    #expect(partial.isClean)
    let remaining = try await admin.routes().map(\.route.rawValue)
    #expect(remaining == ["api"])
    #expect(await project.responseStatus(of: webURL) == 404)
    #expect(await project.responseStatus(of: apiURL) == 200, "the other route must still be served")
    #expect(await admin.isReady(), "the project MUX is still in use")

    let final = try await project.down()

    #expect(final.applications.map(\.name) == ["api"])
    #expect(final.runtime == .stopped)
    #expect(final.isClean)
    #expect(await admin.isReady() == false)
    #expect(try await project.runtime() == nil)
    #expect(try await project.liveRunNames() == [])
    // Attached upstreams are not Tailreg's to stop, however far the teardown goes.
    #expect(apiUpstream.hasExited == false)
    #expect(webUpstream.hasExited == false)
  }

  /// The realistic shape: a foreground `up` is still supervising when `down` arrives, so the two
  /// race to end the same runs. Losing that race is the ordinary case rather than a conflict, and
  /// must not be reported as one.
  @Test
  func `Stopping a supervised project unwinds the supervisor and leaves nothing behind`()
    async throws
  {
    let project = try E2EProject(fixture: "Teardown")
    defer { project.cleanUp() }
    let supervised = try await project.upInBackground()
    #expect(supervised.ready.applications.map(\.name) == ["api", "web"])
    let runtime = try #require(try await project.runtime())

    let result = try await project.down()

    #expect(result.applications.map(\.name) == ["api", "web"])
    #expect(result.applications.allSatisfy { $0.outcome.isDown })
    #expect(
      result.applications.allSatisfy { $0.outcome != .replaced },
      "a run ended by its own supervisor was not superseded by a newer one"
    )
    #expect(result.isClean)

    // The supervisor has nothing left to wait on, so `up` returns rather than hanging.
    _ = try await supervised.task.value

    #expect(await MuxAdminClient(port: runtime.adminPort).isReady() == false)
    #expect(try await project.runtime() == nil)
    #expect(try await project.liveRunNames() == [])
    #expect(await SystemPortProbe().isListening(port: runtime.ingressPort) == false)
  }
}
