import Foundation
import SQLiteData
import TailregCore
import TailregTestSupport
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

    let result = try await context.coordinator().run(DownRequest())

    #expect(result.applications.isEmpty)
    #expect(result.isClean)
    let projects = try await context.database.read { db in try ProjectRecord.all.fetchAll(db) }
    #expect(projects.isEmpty)
  }

  @Test
  func `A managed application is stopped and its run ended`() async throws {
    let context = try Context()
    let project = try context.insertProject()
    let process = try launchSleeper()
    try context.insertRun(project: project, name: "web", process: process)

    let result = try await context.coordinator().run(DownRequest())

    #expect(result.applications.map(\.name) == ["web"])
    #expect(result.applications.first?.outcome == .stopped)
    #expect(result.isClean)
    // Awaited rather than read: `down` observes the exit by probing, which happens before the
    // launcher's own waiter records it, so reading `hasExited` here would race that waiter.
    #expect(await process.waitForExit().wasTerminatedBySignal)
    #expect(try context.liveRunNames(project) == [])
  }

  /// The payoff of recording a start time: a stale record must never reach whatever process
  /// happens to hold that PID now.
  @Test
  func `A run whose start time does not match is not signalled`() async throws {
    let context = try Context()
    let project = try context.insertProject()
    let process = try launchSleeper()
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
    let project = try context.insertProject()
    let web = try launchSleeper()
    let api = try launchSleeper()
    try context.insertRun(project: project, name: "web", process: web)
    try context.insertRun(project: project, name: "api", process: api)

    let result = try await context.coordinator()
      .run(DownRequest(applicationNames: ["web"]))

    #expect(result.applications.map(\.name) == ["web"])
    #expect(await web.waitForExit().wasTerminatedBySignal)
    #expect(api.hasExited == false)
    #expect(try context.liveRunNames(project) == ["api"])
    api.terminateProcessGroup()
  }

  @Test
  func `Stopping an application that is already down is not an error`() async throws {
    let context = try Context()
    let project = try context.insertProject()
    let process = try launchSleeper()
    try context.insertRun(project: project, name: "web", process: process)

    _ = try await context.coordinator().run(DownRequest())
    let again = try await context.coordinator().run(DownRequest(applicationNames: ["web"]))

    #expect(again.applications.first?.outcome == .alreadyDown)
    #expect(again.isClean)
  }

  @Test
  func `An unknown application name is rejected`() async throws {
    let context = try Context()
    _ = try context.insertProject()

    await #expect(throws: DownError.self) {
      try await context.coordinator().run(DownRequest(applicationNames: ["nope"]))
    }
  }

  private struct Context {
    let directory: TempDirectory
    let databasePath: String
    let database: any DatabaseWriter

    /// On disk rather than in memory: `down` takes the runtime lock, and `FileLock` needs a real
    /// path next to the database to take it against.
    init() throws {
      directory = try TempDirectory()
      databasePath = directory.path("tailreg.sqlite")
      database = try TestDatabase.onDisk(in: directory)
    }

    var root: URL { directory.url }

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
  }
}
