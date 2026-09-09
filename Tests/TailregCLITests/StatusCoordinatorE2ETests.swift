import Foundation
import Testing

@testable import TailregCLI

/// The record-level suite decides what `status` concludes from a given set of rows. This decides
/// whether those rows are the ones a real `up` writes: the report is a join across configuration,
/// records, a live MUX and the kernel, and only a real runtime can say the join lines up.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct `Status coordinator E2E tests` {
  @Test
  func `A running project is reported as the MUX and the records actually have it`() async throws {
    let project = try E2EProject(fixture: "Status")
    defer { project.cleanUp() }
    try project.startUpstream(port: 19_114)
    try project.startUpstream(port: 19_113)
    try await project.up()

    let running = try #require(try await project.status().projects.first)

    #expect(running.name == "status")
    #expect(running.exposure == .local)
    #expect(running.mux.state == .running)
    #expect(running.applications.map(\.name) == ["api", "web"])
    #expect(running.applications.allSatisfy { $0.ownership == .attached })
    #expect(running.applications.allSatisfy { $0.state == .running })
    #expect(running.applications.allSatisfy { $0.configured })
    #expect(running.applications.compactMap { $0.route?.path } == ["/api/", "/web/"])
    #expect(running.problems.isEmpty)

    let ingress = try #require(running.mux.ingressPort)
    #expect(running.url?.absoluteString == "http://127.0.0.1:\(ingress)/")
    // The report's URL is worth nothing unless it is the one the MUX serves.
    let published = try #require(running.applications.first { $0.name == "web" }?.route?.url)
    #expect(await project.responseStatus(of: published) == 200)

    try await project.down()
    let stopped = try #require(try await project.status().projects.first)

    #expect(stopped.mux.state == .notRunning)
    #expect(stopped.url == nil)
    #expect(stopped.exposure == nil)
    #expect(stopped.applications.allSatisfy { $0.state == .stopped })
    #expect(stopped.problems.isEmpty, "an orderly teardown leaves nothing to report")
  }
}
