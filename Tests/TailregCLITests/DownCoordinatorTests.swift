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

/// These exercise the path taken when a project has no live MUX, which is where `down`'s record
/// and process handling lives. Route removal and runtime teardown need a running MUX and are
/// covered by the end-to-end suite.
@Suite(.timeLimit(.minutes(1)))
struct `Down coordinator tests` {
  @Test
  func `A directory that was never brought up is reported, not created`() async throws {
    let context = try Context()
    defer { context.cleanUp() }

    let result = try await context.coordinator().run(DownRequest())

    #expect(result.applications.isEmpty)
    #expect(result.isClean)
    let projects = try await context.database.read { db in try ProjectRecord.all.fetchAll(db) }
    #expect(projects.isEmpty)
  }

  @Test
  func `A managed application is stopped and its run ended`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    let process = try context.launchSleeper()
    try context.insertRun(project: project, name: "web", process: process)

    let result = try await context.coordinator().run(DownRequest())

    #expect(result.applications.map(\.name) == ["web"])
    #expect(result.applications.first?.outcome == .stopped)
    #expect(result.isClean)
    #expect(process.hasExited)
    #expect(try context.liveRunNames(project) == [])
  }

  /// The payoff of recording a start time: a stale record must never reach whatever process
  /// happens to hold that PID now.
  @Test
  func `A run whose start time does not match is not signalled`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    let process = try context.launchSleeper()
    try context.insertRun(project: project, name: "web", process: process, startedAt: 1)

    let result = try await context.coordinator().run(DownRequest())

    #expect(result.isClean)
    #expect(process.hasExited == false, "a mismatched witness must not signal the process group")
    #expect(try context.liveRunNames(project) == [])
    process.terminateProcessGroup()
  }

  @Test
  func `An attached application is detached rather than signalled`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    try await context.database.write { db in
      try AppRunRecord
        .insert { AppRunRecord(projectID: project, name: "docs", ownership: .attached) }
        .execute(db)
    }

    let result = try await context.coordinator().run(DownRequest())

    #expect(result.applications.first?.outcome == .detached)
    #expect(result.isClean)
    #expect(try context.liveRunNames(project) == [])
  }

  @Test
  func `Naming one application leaves the others running`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    let web = try context.launchSleeper()
    let api = try context.launchSleeper()
    try context.insertRun(project: project, name: "web", process: web)
    try context.insertRun(project: project, name: "api", process: api)

    let result = try await context.coordinator()
      .run(DownRequest(applicationNames: ["web"]))

    #expect(result.applications.map(\.name) == ["web"])
    #expect(web.hasExited)
    #expect(api.hasExited == false)
    #expect(try context.liveRunNames(project) == ["api"])
    api.terminateProcessGroup()
  }

  @Test
  func `Stopping an application that is already down is not an error`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let project = try context.insertProject()
    let process = try context.launchSleeper()
    try context.insertRun(project: project, name: "web", process: process)

    _ = try await context.coordinator().run(DownRequest())
    let again = try await context.coordinator().run(DownRequest(applicationNames: ["web"]))

    #expect(again.applications.first?.outcome == .alreadyDown)
    #expect(again.isClean)
  }

  @Test
  func `An unknown application name is rejected`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    _ = try context.insertProject()

    await #expect(throws: DownError.self) {
      try await context.coordinator().run(DownRequest(applicationNames: ["nope"]))
    }
  }

  private struct Context {
    let root: URL
    let databasePath: String
    let database: any DatabaseWriter

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailreg-down-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      databasePath = root.appendingPathComponent("tailreg.sqlite").path
      database = try openTailregDatabase(path: databasePath)
    }

    func coordinator() -> DownCoordinator {
      DownCoordinator(
        databasePath: databasePath,
        environment: ["TAILREG_STOP_TIMEOUT_MS": "1000"],
        currentDirectory: root
      )
    }

    func insertProject() throws -> UUIDV7 {
      let project = ProjectRecord(rootPath: root.path, name: "demo")
      try database.write { db in try ProjectRecord.insert { project }.execute(db) }
      return project.id
    }

    func insertRun(
      project: UUIDV7,
      name: String,
      process: LaunchedProcess,
      startedAt: Int64? = nil
    ) throws {
      let run = AppRunRecord(
        projectID: project,
        name: name,
        ownership: .managed,
        pid: Int(process.pid),
        processGroupID: Int(getpgid(process.pid)),
        processStartedAt: startedAt ?? processStartTime(of: process.pid)
      )
      try database.write { db in try AppRunRecord.insert { run }.execute(db) }
    }

    func liveRunNames(_ project: UUIDV7) throws -> [String] {
      try database.read { db in try AppRunRecord.live(for: project).fetchAll(db) }.map(\.name)
    }

    /// Foundation's `Process` gives the child the spawning thread's signal mask, and Swift
    /// concurrency threads block nearly everything. Applications launched by `up` get a clean
    /// slate from `_exec`; these are launched directly, so the mask is cleared here.
    func launchSleeper() throws -> LaunchedProcess {
      var empty = sigset_t()
      sigemptyset(&empty)
      pthread_sigmask(SIG_SETMASK, &empty, nil)
      return try SystemProcessLauncher()
        .launch(ProcessCommand(executable: "/bin/sleep", arguments: ["60"]))
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }
  }
}
