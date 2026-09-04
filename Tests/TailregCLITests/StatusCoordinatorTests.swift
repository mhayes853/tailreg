import Foundation
import SQLiteData
import TailregCore
import Testing
import UUIDV7

@testable import TailregCLI

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// These pin what `status` concludes from a given set of records, which is the whole of the
/// command: the report is a join of configuration, records and observation, and every
/// interesting case is a disagreement between them.
@Suite(.timeLimit(.minutes(1)))
struct `Status coordinator tests` {
  @Test
  func `A directory that was never brought up is described, not recorded`() async throws {
    let context = try Context()
    defer { context.cleanUp() }

    let report = try await context.coordinator().run(StatusRequest())

    let project = try #require(report.projects.first)
    #expect(report.projects.count == 1)
    #expect(project.name == "demo")
    #expect(project.mux.state == .notRunning)
    #expect(project.url == nil)
    #expect(project.exposure == nil)
    #expect(project.applications.map(\.name) == ["api", "jobs", "web"])
    #expect(project.applications.allSatisfy { $0.state == .stopped })
    #expect(project.problems.isEmpty)
    // Observing a directory must not bring a project into existence.
    let records = try await context.database.read { db in try ProjectRecord.all.fetchAll(db) }
    #expect(records.isEmpty)
  }

  /// The load-bearing difference between `status` and the lifecycle commands: `up` and `down`
  /// would end this record, which is exactly the evidence someone runs `status` to see.
  @Test
  func `A run whose process is gone is reported as stale, not reclaimed`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    try context.insertRuntime(project: project)
    try context.insertRun(project: project, name: "web", pid: try await context.reapedPID())

    let report = try await context.coordinator().run(StatusRequest())

    let status = try #require(report.projects.first)
    #expect(status.applications.first { $0.name == "web" }?.state == .stale)
    #expect(status.problems.map(\.kind) == [.staleProcess])
    #expect(status.problems.first?.subject == "web")
    #expect(try context.liveRunNames(project) == ["web"], "the record must survive being read")
  }

  /// `reclaimAbandoned` deliberately leaves these alone because their identity cannot be
  /// disproved. Reporting one as a fault would invent a problem the runtime does not have.
  @Test
  func `A managed run with no recorded start time is unverified, not a problem`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    try context.insertRuntime(project: project)
    try context.insertRun(project: project, name: "web", pid: Int(getpid()), startedAt: nil)

    let report = try await context.coordinator().run(StatusRequest())

    let status = try #require(report.projects.first)
    #expect(status.applications.first { $0.name == "web" }?.state == .unverified)
    #expect(status.problems.isEmpty)
  }

  /// An attached run has no PID by construction, so its upstream is the only evidence there is.
  @Test
  func `An attached application is judged by its upstream`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    try context.insertRuntime(project: project)
    let listening = try context.insertRoute(project: project, route: "api", port: 19_201)
    let silent = try context.insertRoute(project: project, route: "web", port: 19_202)
    try context.insertAttachedRun(project: project, name: "api", route: listening)
    try context.insertAttachedRun(project: project, name: "web", route: silent)

    let report = try await context.coordinator(listening: [19_201]).run(StatusRequest())

    let status = try #require(report.projects.first)
    #expect(status.applications.first { $0.name == "api" }?.state == .running)
    #expect(status.applications.first { $0.name == "web" }?.state == .unreachable)
    #expect(status.problems.map(\.kind) == [.notListening])
    #expect(status.problems.first?.detail.contains("127.0.0.1:19202") == true)
  }

  /// The payoff of recording exposure rather than inferring it: this state and a local-only
  /// runtime are otherwise identical, and only one of them is a fault.
  @Test
  func `A tailnet runtime with no live binding is reported as missing`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    try context.insertRuntime(project: project, exposure: .tailnet)

    let report = try await context.coordinator().run(StatusRequest())

    let status = try #require(report.projects.first)
    #expect(status.exposure == .tailnet)
    #expect(status.url == nil)
    #expect(status.problems.map(\.kind) == [.missing])
    #expect(status.problems.first?.subject == "binding")
  }

  @Test
  func `A recorded binding supplies the project URL`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    let runtime = try context.insertRuntime(project: project, exposure: .tailnet)
    try context.insertBinding(localPort: runtime.ingressPort)

    let report = try await context.coordinator().run(StatusRequest())

    let status = try #require(report.projects.first)
    #expect(status.url?.absoluteString == "https://demo.tail1234.ts.net/")
    #expect(status.problems.isEmpty)
  }

  @Test
  func `A local runtime is reachable on the MUX listener`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    let runtime = try context.insertRuntime(project: project, exposure: .local)

    let report = try await context.coordinator().run(StatusRequest())

    let status = try #require(report.projects.first)
    #expect(status.url?.absoluteString == "http://127.0.0.1:\(runtime.ingressPort)/")
    #expect(status.problems.isEmpty)
  }

  /// A route is published after its run is recorded and removed before that run is ended, so
  /// this is the trace of an invocation that died between the two.
  @Test
  func `A route with no owning run is reported`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    try context.insertRuntime(project: project)
    _ = try context.insertRoute(project: project, route: "api", port: 19_201)

    let report = try await context.coordinator().run(StatusRequest())

    let status = try #require(report.projects.first)
    #expect(status.problems.map(\.kind) == [.orphanedRoute])
    #expect(status.problems.first?.subject == "api")
  }

  @Test
  func `An application running outside the configuration is named`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    try context.insertRuntime(project: project)
    let route = try context.insertRoute(project: project, route: "ghost", port: 19_203)
    try context.insertRun(project: project, name: "ghost", pid: Int(getpid()), route: route)

    let report = try await context.coordinator().run(StatusRequest())

    let status = try #require(report.projects.first)
    let ghost = try #require(status.applications.first { $0.name == "ghost" })
    #expect(ghost.configured == false)
    #expect(ghost.state == .running)
    #expect(status.problems.map(\.kind) == [.notConfigured])
  }

  /// A matching process only proves a MUX was started; an admin API that answers proves one is
  /// serving. The weaker evidence is reported as such.
  @Test
  func `A MUX that does not answer is unreachable while its process lives`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    try context.insertRuntime(project: project)

    let report = try await context.coordinator(muxIsReady: false).run(StatusRequest())

    let status = try #require(report.projects.first)
    #expect(status.mux.state == .unreachable)
    #expect(status.problems.map(\.kind) == [.unreachable])
    #expect(status.problems.first?.subject == "mux")
  }

  @Test
  func `Every known project is reported with all`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    _ = try context.insertProject()
    let other = context.root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try await context.database.write { db in
      try ProjectRecord.insert { ProjectRecord(rootPath: other.path, name: "aardvark") }
        .execute(db)
    }

    let report = try await context.coordinator().run(StatusRequest(allProjects: true))

    #expect(report.projects.map(\.name) == ["aardvark", "demo"])
  }

  private struct Context {
    let root: URL
    let databasePath: String
    let database: any DatabaseWriter

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailreg-status-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      databasePath = root.appendingPathComponent("tailreg.sqlite").path
      database = try openTailregDatabase(path: databasePath)
      try Data(Self.configuration.utf8)
        .write(to: root.appendingPathComponent("tailreg.toml"))
    }

    /// `jobs` is deliberately unexposed, so the report has to distinguish "no route by choice"
    /// from "no route because nothing is running".
    private static let configuration = """
      [project]
      name = "demo"

      [apps.api]
      route = "api"
      port = 19201
      command = ["true"]

      [apps.web]
      route = "web"
      port = 19202
      command = ["true"]

      [apps.jobs]
      expose = false
      command = ["true"]
      """

    func coordinator(
      listening: Set<Int> = [],
      muxIsReady: Bool = true
    ) -> StatusCoordinator {
      StatusCoordinator(
        databasePath: databasePath,
        currentDirectory: root,
        portProbe: StubPortProbe(listening: listening),
        muxIsReady: { _ in muxIsReady }
      )
    }

    func insertProject() throws -> ProjectRecord {
      let project = ProjectRecord(rootPath: root.path, name: "demo")
      try database.write { db in try ProjectRecord.insert { project }.execute(db) }
      return project
    }

    @discardableResult
    func insertRuntime(
      project: ProjectRecord,
      exposure: ProjectExposure = .local
    ) throws -> MuxRunRecord {
      let runtime = MuxRunRecord(
        projectID: project.id,
        pid: Int(getpid()),
        processStartedAt: processStartTime(of: getpid()),
        ingressPort: 39_428,
        adminPort: 39_429,
        exposure: exposure
      )
      try database.write { db in try MuxRunRecord.insert { runtime }.execute(db) }
      return runtime
    }

    func insertRoute(
      project: ProjectRecord,
      route: String,
      port: Int
    ) throws -> MuxRouteRecord {
      let record = MuxRouteRecord(
        muxID: project.muxID,
        name: route,
        route: route,
        upstreamURL: "http://127.0.0.1:\(port)",
        createdAt: Date()
      )
      try database.write { db in
        if try MuxInstanceRecord.find(project.muxID).fetchOne(db) == nil {
          try MuxInstanceRecord.insert { MuxInstanceRecord(id: project.muxID) }.execute(db)
        }
        try MuxRouteRecord.insert { record }.execute(db)
      }
      return record
    }

    func insertRun(
      project: ProjectRecord,
      name: String,
      pid: Int,
      startedAt: Int64? = 1,
      route: MuxRouteRecord? = nil
    ) throws {
      let run = AppRunRecord(
        projectID: project.id,
        name: name,
        ownership: .managed,
        routeID: route?.id,
        pid: pid,
        processGroupID: pid,
        processStartedAt: startedAt.map { _ in processStartTime(of: Int32(pid)) ?? 1 }
      )
      try database.write { db in try AppRunRecord.insert { run }.execute(db) }
    }

    func insertAttachedRun(
      project: ProjectRecord,
      name: String,
      route: MuxRouteRecord
    ) throws {
      let run = AppRunRecord(
        projectID: project.id,
        name: name,
        ownership: .attached,
        routeID: route.id
      )
      try database.write { db in try AppRunRecord.insert { run }.execute(db) }
    }

    func insertBinding(localPort: Int) throws {
      let binding = TailscaleBindingRecord(
        hostname: "demo.tail1234.ts.net",
        localPort: localPort,
        tailnetPort: 443,
        proto: .https,
        mountPath: "/",
        status: .active,
        createdAt: Date()
      )
      try database.write { db in try TailscaleBindingRecord.insert { binding }.execute(db) }
    }

    /// A PID that is certainly free: the process is waited on before the number is handed back,
    /// so it is neither alive nor a zombie that `kill(pid, 0)` would still find.
    func reapedPID() async throws -> Int {
      var empty = sigset_t()
      sigemptyset(&empty)
      pthread_sigmask(SIG_SETMASK, &empty, nil)
      let process = try SystemProcessLauncher()
        .launch(ProcessCommand(executable: "/bin/sleep", arguments: ["60"]))
      process.terminate()
      _ = await process.waitForExit()
      return Int(process.pid)
    }

    func liveRunNames(_ project: ProjectRecord) throws -> [String] {
      try database.read { db in try AppRunRecord.live(for: project.id).fetchAll(db) }.map(\.name)
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }
  }

  private struct StubPortProbe: PortProbe {
    let listening: Set<Int>

    func isListening(host: String, port: PortNumber) async -> Bool {
      listening.contains(port.intValue)
    }
  }
}
