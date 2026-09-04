import Foundation
import TailregCore
import Testing

@testable import TailregCLI

/// A listening port is not proof that the application launched is the one listening. These drive
/// `up` against ports that something else holds, before and after the launch.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct `Up readiness E2E tests` {
  @Test
  func `A port that is already in use is refused before anything is launched`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let squatter = try context.startUpstream(port: 19_115)
    defer { squatter.terminate() }

    await #expect(throws: UpError.self) {
      try await context.up(command: ["sleep", "30"], port: 19_115)
    }
    #expect(try await context.liveRunNames() == [])
  }

  /// The pre-launch check passes, then something else takes the port while the application is
  /// still starting. Readiness must not be credited to the wrong process.
  @Test
  func `A listener that is not the launched process fails readiness`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let fixture = context.fixture
    let squatter = Task<LaunchedProcess, any Error> {
      try await Task.sleep(for: .milliseconds(500))
      return try Context.launchUpstream(port: 19_116, fixture: fixture)
    }
    defer { squatter.cancel() }

    let failure = await #expect(throws: UpError.self) {
      try await context.up(command: ["sleep", "30"], port: 19_116)
    }
    if case .portOwnedElsewhere = failure {
    } else {
      Issue.record(
        "expected the port to be reported as owned elsewhere, got \(String(describing: failure))"
      )
    }
    #expect(try await context.liveRunNames() == [], "a failed launch leaves no live run behind")
    (try? await squatter.value)?.terminate()
  }

  private final class Context {
    let fixture: URL
    let executable: URL
    let stateDirectory: URL
    let databasePath: String
    let environment: [String: String]
    private var upstreams: [LaunchedProcess] = []

    init() throws {
      let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      fixture = packageRoot.appendingPathComponent("Tests/Fixtures/Teardown")
      executable = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("tailreg")
      stateDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailreg-readiness-e2e-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
      databasePath = stateDirectory.appendingPathComponent("tailreg.sqlite").path
      var environment = ProcessInfo.processInfo.environment
      environment["TAILREG_STARTUP_TIMEOUT_MS"] = "15000"
      environment["TAILREG_STOP_TIMEOUT_MS"] = "2000"
      self.environment = environment
    }

    func startUpstream(port: Int) throws -> LaunchedProcess {
      let process = try Self.launchUpstream(port: port, fixture: fixture)
      upstreams.append(process)
      return process
    }

    static func launchUpstream(port: Int, fixture: URL) throws -> LaunchedProcess {
      try SystemProcessLauncher()
        .launch(
          ProcessCommand(
            executable: "node",
            arguments: [fixture.appendingPathComponent("server.mjs").path],
            workingDirectory: fixture,
            environment: ["PORT": String(port)]
          )
        )
    }

    @discardableResult
    func up(command: [String], port: Int) async throws -> UpResult {
      try await UpCoordinator(
        databasePath: databasePath,
        executableURL: executable,
        environment: environment,
        currentDirectory: fixture
      )
      .run(
        UpRequest(
          projectPath: fixture.path,
          adHocApplication: "squat",
          route: "squat",
          port: PortNumber(port),
          command: command,
          localOnly: true
        )
      )
    }

    func liveRunNames() async throws -> [String] {
      let database = try openTailregDatabase(path: databasePath)
      guard
        let project = try await ResolvedProject.lookUp(
          database: database,
          explicitPath: fixture.path,
          currentDirectory: fixture
        )
      else { return [] }
      return
        try await database.read { database in
          try AppRunRecord.live(for: project.record.id).fetchAll(database)
        }
        .map(\.name)
    }

    func cleanUp() {
      // A failed `up` rolls its own runtime back, so only the squatters are left to stop.
      for upstream in upstreams where !upstream.hasExited { upstream.terminate() }
      try? FileManager.default.removeItem(at: stateDirectory)
    }
  }
}
