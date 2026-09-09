import Foundation
import SQLiteData
import TailregCore

@testable import TailregCLI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// One end-to-end project: a fixture directory, a state directory of its own, and the three
/// coordinators driven against them.
///
/// Every suite that starts a real MUX needs the same setup, and the parts that matter are the
/// ones easy to get subtly wrong: the timeout overrides that keep a slow machine from failing a
/// test about something else, and the stranded-process sweep that stops a half-finished run from
/// outliving the state directory that names its processes.
final class E2EProject {
  let fixture: URL
  /// The one server every CLI fixture runs, shared rather than copied per fixture.
  let upstreamServer: URL
  let executable: URL
  let stateDirectory: URL
  let databasePath: String
  let environment: [String: String]
  let database: any DatabaseWriter
  private var upstreams: [LaunchedProcess] = []
  private var supervisors: [Task<UpResult, any Error>] = []

  /// - Parameters:
  ///   - fixture: A directory name under `Tests/Fixtures`.
  ///   - environment: Extra variables for the coordinators, on top of the shared timeouts.
  init(fixture name: String, environment extra: [String: String] = [:]) throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    fixture = packageRoot.appendingPathComponent("Tests/Fixtures/\(name)")
    upstreamServer = packageRoot.appendingPathComponent("Tests/Fixtures/Upstream/server.mjs")
    executable = builtTailregExecutable()
    stateDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tailreg-e2e-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    databasePath = stateDirectory.appendingPathComponent("tailreg.sqlite").path
    var environment = ProcessInfo.processInfo.environment
    environment["TAILREG_STARTUP_TIMEOUT_MS"] = "15000"
    environment["TAILREG_STOP_TIMEOUT_MS"] = "2000"
    self.environment = environment.merging(extra) { _, extra in extra }
    database = try openTailregDatabase(path: databasePath)
  }

  /// The shared fixture server on `port`, run outside Tailreg. Stands in for an application that
  /// was already listening when the project came up.
  @discardableResult
  func startUpstream(port: Int) throws -> LaunchedProcess {
    let process = try SystemProcessLauncher()
      .launch(
        ProcessCommand(
          executable: "node",
          arguments: [upstreamServer.path],
          workingDirectory: fixture,
          environment: ["PORT": String(port)]
        )
      )
    upstreams.append(process)
    return process
  }

  @discardableResult
  func up(
    _ selection: UpRequest.Selection = .configured([]),
    onReady: @escaping @Sendable (UpResult) async -> Void = { _ in }
  ) async throws -> UpResult {
    try await upCoordinator()
      .run(
        UpRequest(projectPath: fixture.path, selection: selection, localOnly: true),
        onReady: onReady
      )
  }

  /// Attaches one ad hoc application and returns its public URL. With no process to supervise,
  /// `up` publishes the route and returns, leaving the MUX for the next call to reuse.
  func attach(_ name: String, to port: Int) async throws -> URL {
    let upstream = LoopbackURL(port: PortNumber(port)!)
    let result = try await up(
      .adHoc(name: name, route: MuxRouteName(rawValue: name), source: .attached(upstream))
    )
    guard let url = result.applications.first?.publicURL else {
      throw E2EProjectError.applicationWasNotPublished(name)
    }
    return url
  }

  /// Brings the configured applications up under a supervisor that keeps running, and returns
  /// once they are ready.
  func upInBackground() async throws -> (task: Task<UpResult, any Error>, ready: UpResult) {
    let coordinator = upCoordinator()
    let request = UpRequest(
      projectPath: fixture.path,
      selection: .configured([]),
      localOnly: true
    )
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
      throw E2EProjectError.projectWasNotBroughtUp
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
    .run(DownRequest(projectPath: fixture.path, applicationNames: applications))
  }

  /// The real coordinator, with nothing stubbed: the MUX admin API and the upstream probes are
  /// the point of an end-to-end report.
  func status() async throws -> StatusReport {
    try await StatusCoordinator(databasePath: databasePath, currentDirectory: fixture)
      .run(StatusRequest(projectPath: fixture.path))
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
    for supervisor in supervisors { supervisor.cancel() }
    for upstream in upstreams where !upstream.hasExited { upstream.terminate() }
    stopStrandedProcesses()
    try? FileManager.default.removeItem(at: stateDirectory)
  }

  /// A test that fails partway leaves the project running, and the records that name those
  /// processes are in the state directory this is about to remove. Nothing would ever reap them
  /// afterwards, so anything still recorded as live is killed outright.
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

enum E2EProjectError: Error, CustomStringConvertible {
  case applicationWasNotPublished(String)
  case projectWasNotBroughtUp

  var description: String {
    switch self {
    case .applicationWasNotPublished(let name): "'\(name)' was brought up without a route"
    case .projectWasNotBroughtUp: "the project never reported that it was ready"
    }
  }
}
