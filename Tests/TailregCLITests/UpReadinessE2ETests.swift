import Foundation
import SQLiteData
import TailregCore
import TailregTestSupport
import Testing

@testable import TailregCLI

/// A listening port is not proof that the application launched is the one listening. These drive
/// `up` against ports that something else holds, before and after the launch.
///
/// The squatter is a socket bound by the test process itself rather than another program: the
/// point is that the listener is not the launched process, and holding the port in-process makes
/// that true without a second binary to start and reap.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct `Up readiness E2E tests` {
  @Test
  func `A port that is already in use is refused before anything is launched`() async throws {
    let project = try E2EProject(fixture: "Teardown")
    defer { project.cleanUp() }
    let squatter = try LoopbackListener(port: PortNumber(19_115))
    defer { squatter.stop() }

    await #expect(throws: UpError.self) {
      try await project.up(adHocCommand: ["sleep", "30"], port: 19_115)
    }
    #expect(try await project.liveRunNames() == [])
  }

  /// The pre-launch check passes, then something else takes the port while the application is
  /// still starting. Readiness must not be credited to the wrong process.
  @Test
  func `A listener that is not the launched process fails readiness`() async throws {
    let project = try E2EProject(fixture: "Teardown")
    defer { project.cleanUp() }
    let squatter = Task<LoopbackListener, any Error> {
      try await Task.sleep(for: .milliseconds(500))
      return try LoopbackListener(port: PortNumber(19_116))
    }
    defer { squatter.cancel() }

    let failure = await #expect(throws: UpError.self) {
      try await project.up(adHocCommand: ["sleep", "30"], port: 19_116)
    }
    if case .portOwnedElsewhere = failure {
    } else {
      Issue.record(
        "expected the port to be reported as owned elsewhere, got \(String(describing: failure))"
      )
    }
    #expect(try await project.liveRunNames() == [], "a failed launch leaves no live run behind")
    (try? await squatter.value)?.stop()
  }

  /// A failed invocation has to name the operation that failed, not just fail.
  @Test
  func `Records the operation a refused port failed`() async throws {
    let project = try E2EProject(fixture: "Teardown")
    defer { project.cleanUp() }
    let squatter = try LoopbackListener(port: PortNumber(19_115))
    defer { squatter.stop() }

    await #expect(throws: UpError.self) {
      try await project.up(adHocCommand: ["sleep", "30"], port: 19_115)
    }

    let command = try #require(
      try await project.database.read { database in try CommandRunRecord.all.fetchOne(database) }
    )
    #expect(command.outcome == .failed)
    // `UpError` describes itself, so what is recorded is the message the user was shown rather
    // than the name of a case only this code knows.
    #expect(command.failure?.contains("is already in use") == true)

    let operations = try await project.database.read { database in
      try OperationRunRecord.all(of: command.id).fetchAll(database)
    }
    let failed = operations.filter { $0.outcome == .failed }
    #expect(
      failed.map(\.operation).sorted() == [
        "UpCoordinator.launchApplication", "UpCoordinator.startApplication"
      ]
    )
    #expect(failed.allSatisfy { $0.failure?.contains("is already in use") == true })
  }
}

extension E2EProject {
  /// Brings up one ad hoc command expected to listen on `port`.
  @discardableResult
  fileprivate func up(adHocCommand command: [String], port: Int) async throws -> UpResult {
    try await up(
      .adHoc(
        name: "squat",
        route: MuxRouteName(rawValue: "squat"),
        source: .command(command, port: PortNumber(port))
      )
    )
  }
}
