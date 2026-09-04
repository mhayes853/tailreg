import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import SQLiteData
import TailregCore
import Testing

@testable import TailregCLI

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// The record-level suite decides what `status` concludes from a given set of rows. This decides
/// whether those rows are the ones a real `up` writes: the report is a join across configuration,
/// records, a live MUX and the kernel, and only a real runtime can say the join lines up.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct `Status coordinator E2E tests` {
  @Test
  func `A running project is reported as the MUX and the records actually have it`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    try context.startUpstream(port: 19_114)
    try context.startUpstream(port: 19_113)
    try await context.up()

    let running = try #require(try await context.status().projects.first)

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
    #expect(await context.responseStatus(of: published) == 200)

    try await context.down()
    let stopped = try #require(try await context.status().projects.first)

    #expect(stopped.mux.state == .notRunning)
    #expect(stopped.url == nil)
    #expect(stopped.exposure == nil)
    #expect(stopped.applications.allSatisfy { $0.state == .stopped })
    #expect(stopped.problems.isEmpty, "an orderly teardown leaves nothing to report")
  }

  private final class Context {
    let fixture: URL
    let executable: URL
    let stateDirectory: URL
    let databasePath: String
    let environment: [String: String]
    let database: any DatabaseWriter
    private var upstreams: [LaunchedProcess] = []

    init() throws {
      let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      fixture = packageRoot.appendingPathComponent("Tests/Fixtures/Status")
      executable = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("tailreg")
      stateDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailreg-status-e2e-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
      databasePath = stateDirectory.appendingPathComponent("tailreg.sqlite").path
      var environment = ProcessInfo.processInfo.environment
      environment["TAILREG_STARTUP_TIMEOUT_MS"] = "15000"
      environment["TAILREG_STOP_TIMEOUT_MS"] = "2000"
      self.environment = environment
      database = try openTailregDatabase(path: databasePath)
    }

    func startUpstream(port: Int) throws {
      let process = try SystemProcessLauncher()
        .launch(
          ProcessCommand(
            executable: "node",
            arguments: [fixture.appendingPathComponent("server.mjs").path],
            workingDirectory: fixture,
            environment: ["PORT": String(port)]
          )
        )
      upstreams.append(process)
    }

    @discardableResult
    func up() async throws -> UpResult {
      let coordinator = UpCoordinator(
        databasePath: databasePath,
        executableURL: executable,
        environment: environment,
        currentDirectory: fixture
      )
      return try await coordinator.run(UpRequest(projectPath: fixture.path, localOnly: true))
    }

    func down() async throws {
      let coordinator = DownCoordinator(
        databasePath: databasePath,
        executableURL: executable,
        environment: environment,
        currentDirectory: fixture
      )
      _ = try await coordinator.run(DownRequest(projectPath: fixture.path, localOnly: true))
    }

    /// The real coordinator, with nothing stubbed: the MUX admin API and the upstream probes are
    /// the point of this suite.
    func status() async throws -> StatusReport {
      let coordinator = StatusCoordinator(
        databasePath: databasePath,
        currentDirectory: fixture
      )
      return try await coordinator.run(StatusRequest(projectPath: fixture.path))
    }

    /// Requests without a cookie jar. The MUX falls back to the last selected route when a path
    /// does not match, which would otherwise let one route answer for another.
    func responseStatus(of url: URL) async -> Int? {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpShouldSetCookies = false
      configuration.httpCookieAcceptPolicy = .never
      configuration.timeoutIntervalForRequest = 5
      let session = URLSession(configuration: configuration)
      defer { session.finishTasksAndInvalidate() }
      let response = try? await session.data(from: url)
      return (response?.1 as? HTTPURLResponse)?.statusCode
    }

    func cleanUp() {
      for upstream in upstreams where !upstream.hasExited { upstream.terminate() }
      stopStrandedProcesses()
      try? FileManager.default.removeItem(at: stateDirectory)
    }

    /// A test that fails partway leaves the project running, and the records that name those
    /// processes are in the state directory this is about to remove. Nothing would ever reap
    /// them afterwards, so anything still recorded as live is killed outright.
    private func stopStrandedProcesses() {
      let runtimes =
        (try? database.read { database in
          try MuxRunRecord.where { $0.endedAt.is(nil) }.fetchAll(database)
        }) ?? []
      for runtime in runtimes { kill(pid_t(runtime.pid), SIGKILL) }

      let applications =
        (try? database.read { database in
          try AppRunRecord.where { $0.endedAt.is(nil) }.fetchAll(database)
        }) ?? []
      for group in applications.compactMap(\.processGroupID) { kill(-pid_t(group), SIGKILL) }
    }
  }
}
