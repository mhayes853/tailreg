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
    let context = try Context()
    defer { context.cleanUp() }
    let apiUpstream = try context.startUpstream(port: 19_112)
    let webUpstream = try context.startUpstream(port: 19_111)
    let apiURL = try await context.attach("api", to: 19_112)
    let webURL = try await context.attach("web", to: 19_111)

    let runtime = try #require(try await context.runtime())
    let admin = MuxAdminClient(port: runtime.adminPort)
    let published = try await admin.routes().map(\.route).sorted()
    #expect(published == ["api", "web"])
    #expect(await context.status(of: webURL) == 200)

    let partial = try await context.down(["web"])

    #expect(partial.applications.map(\.name) == ["web"])
    #expect(partial.applications.first?.outcome == .detached)
    #expect(partial.runtime == .stillInUse(routes: 1))
    #expect(partial.isClean)
    let remaining = try await admin.routes().map(\.route)
    #expect(remaining == ["api"])
    #expect(await context.status(of: webURL) == 404)
    #expect(await context.status(of: apiURL) == 200, "the other route must still be served")
    #expect(await admin.isReady(), "the project MUX is still in use")

    let final = try await context.down()

    #expect(final.applications.map(\.name) == ["api"])
    #expect(final.runtime == .stopped)
    #expect(final.isClean)
    #expect(await admin.isReady() == false)
    #expect(try await context.runtime() == nil)
    #expect(try await context.liveRunNames() == [])
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
    let context = try Context()
    defer { context.cleanUp() }
    let supervised = try await context.upInBackground()
    #expect(supervised.ready.applications.map(\.name) == ["api", "web"])
    let runtime = try #require(try await context.runtime())

    let result = try await context.down()

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
    #expect(try await context.runtime() == nil)
    #expect(try await context.liveRunNames() == [])
    let ingress = try #require(PortNumber(runtime.ingressPort))
    #expect(await SystemPortProbe().isListening(port: ingress) == false)
  }

  private final class Context {
    let fixture: URL
    let executable: URL
    let stateDirectory: URL
    let databasePath: String
    let environment: [String: String]
    let database: any DatabaseWriter
    private var upstreams: [LaunchedProcess] = []
    private var supervisors: [Task<UpResult, any Error>] = []

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
        .appendingPathComponent("tailreg-down-e2e-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
      databasePath = stateDirectory.appendingPathComponent("tailreg.sqlite").path
      var environment = ProcessInfo.processInfo.environment
      environment["TAILREG_STARTUP_TIMEOUT_MS"] = "15000"
      environment["TAILREG_STOP_TIMEOUT_MS"] = "2000"
      self.environment = environment
      database = try openTailregDatabase(path: databasePath)
    }

    /// Runs the fixture server outside Tailreg, standing in for an application that was already
    /// listening when the project came up.
    func startUpstream(port: Int) throws -> LaunchedProcess {
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
      return process
    }

    /// Attaches one ad hoc application and returns its public URL. With no process to supervise,
    /// `up` publishes the route and returns, leaving the MUX for the next call to reuse.
    func attach(_ name: String, to port: Int) async throws -> URL {
      let result = try await upCoordinator()
        .run(
          UpRequest(
            projectPath: fixture.path,
            adHocApplication: name,
            route: name,
            attachURL: URL(string: "http://127.0.0.1:\(port)")!,
            localOnly: true
          )
        )
      guard let url = result.applications.first?.publicURL else {
        throw E2EError.applicationWasNotPublished(name)
      }
      return url
    }

    /// Brings the configured applications up under a supervisor that keeps running, and returns
    /// once they are ready.
    func upInBackground() async throws -> (task: Task<UpResult, any Error>, ready: UpResult) {
      let coordinator = upCoordinator()
      let request = UpRequest(projectPath: fixture.path, localOnly: true)
      let (stream, continuation) = AsyncStream<UpResult>.makeStream()
      let task = Task {
        defer { continuation.finish() }
        return try await coordinator.run(request) { continuation.yield($0) }
      }
      supervisors.append(task)
      var results = stream.makeAsyncIterator()
      guard let ready = await results.next() else {
        // `up` finished without ever being ready, so awaiting it surfaces the real reason.
        _ = try await task.value
        throw E2EError.projectWasNotBroughtUp
      }
      return (task, ready)
    }

    @discardableResult
    func down(_ applications: [String] = []) async throws -> DownResult {
      try await DownCoordinator(
        databasePath: databasePath,
        executableURL: executable,
        environment: environment,
        currentDirectory: fixture
      )
      .run(
        DownRequest(
          projectPath: fixture.path,
          applicationNames: applications,
          localOnly: true
        )
      )
    }

    func runtime() async throws -> MuxRunRecord? {
      guard let project = try await project() else { return nil }
      let controller = MuxProcessController(
        database: database,
        databasePath: databasePath,
        executableURL: executable,
        terminator: ProcessTerminator()
      )
      return try await controller.liveRun(for: project.record.id)
    }

    func liveRunNames() async throws -> [String] {
      guard let project = try await project() else { return [] }
      let runs = try await database.read { database in
        try AppRunRecord.live(for: project.record.id).fetchAll(database)
      }
      return runs.map(\.name)
    }

    /// Requests without a cookie jar. The MUX falls back to the last selected route when a path
    /// does not match, which would otherwise let one route answer for another after removal.
    func status(of url: URL) async -> Int? {
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
      for supervisor in supervisors { supervisor.cancel() }
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

    private func project() async throws -> ResolvedProject? {
      try await ResolvedProject.lookUp(
        database: database,
        explicitPath: fixture.path,
        currentDirectory: fixture
      )
    }

    private func upCoordinator() -> UpCoordinator {
      UpCoordinator(
        databasePath: databasePath,
        executableURL: executable,
        environment: environment,
        currentDirectory: fixture
      )
    }
  }

  private enum E2EError: Error, CustomStringConvertible {
    case applicationWasNotPublished(String)
    case projectWasNotBroughtUp

    var description: String {
      switch self {
      case .applicationWasNotPublished(let name): "'\(name)' was brought up without a route"
      case .projectWasNotBroughtUp: "the project never reported that it was ready"
      }
    }
  }
}
