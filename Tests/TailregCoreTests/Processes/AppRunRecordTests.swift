import Foundation
import SQLiteData
import Testing
import UUIDV7

@testable import TailregCore

@Suite
struct `Application run record tests` {
  @Test
  func `Only one run of an application is live at a time`() throws {
    let database = try memoryDatabase()
    let project = try insertProject(in: database)

    try database.write { db in
      try AppRunRecord.insert { managedRun(project: project, name: "web", pid: 4001) }.execute(db)
    }

    #expect(throws: (any Error).self) {
      try database.write { db in
        try AppRunRecord.insert { managedRun(project: project, name: "web", pid: 4002) }.execute(db)
      }
    }
  }

  @Test
  func `A replacement run is allowed once the previous one has ended`() throws {
    let database = try memoryDatabase()
    let project = try insertProject(in: database)
    let first = managedRun(project: project, name: "web", pid: 4001)

    try database.write { db in
      try AppRunRecord.insert { first }.execute(db)
      #expect(try AppRunRecord.end(first.id, in: db))
      try AppRunRecord.insert { managedRun(project: project, name: "web", pid: 4002) }.execute(db)
    }

    let live = try database.read { db in try AppRunRecord.live(for: project).fetchAll(db) }
    #expect(live.map(\.pid) == [4002])
  }

  /// The property the whole design rests on: exactly one of several racing supervisors is
  /// entitled to tear the application's route down.
  @Test
  func `Ending a run succeeds for exactly one caller`() throws {
    let database = try memoryDatabase()
    let project = try insertProject(in: database)
    let run = managedRun(project: project, name: "api", pid: 4100)

    try database.write { db in
      try AppRunRecord.insert { run }.execute(db)
      #expect(try AppRunRecord.end(run.id, in: db))
      #expect(try AppRunRecord.end(run.id, in: db) == false)
    }
  }

  @Test
  func `An attached run records no process`() throws {
    let database = try memoryDatabase()
    let project = try insertProject(in: database)

    #expect(throws: (any Error).self) {
      try database.write { db in
        try AppRunRecord
          .insert {
            AppRunRecord(projectID: project, name: "docs", ownership: .attached, pid: 4200)
          }
          .execute(db)
      }
    }
  }

  @Test
  func `A run whose process is gone is reclaimed`() throws {
    let database = try memoryDatabase()
    let project = try insertProject(in: database)
    // A PID that cannot be running paired with a start time that cannot match.
    let stale = managedRun(project: project, name: "web", pid: 0x7FFF_FFFE, startedAt: 1)

    try database.write { db in
      try AppRunRecord.insert { stale }.execute(db)
      let reclaimed = try AppRunRecord.reclaimAbandoned(for: project, in: db)
      #expect(reclaimed.map(\.name) == ["web"])
    }
  }

  @Test
  func `A run without a start time is left alone rather than assumed dead`() throws {
    let database = try memoryDatabase()
    let project = try insertProject(in: database)
    let unverifiable = managedRun(
      project: project,
      name: "web",
      pid: 0x7FFF_FFFE,
      startedAt: nil
    )

    try database.write { db in
      try AppRunRecord.insert { unverifiable }.execute(db)
      #expect(try AppRunRecord.reclaimAbandoned(for: project, in: db).isEmpty)
    }
  }

  @Test
  func `The live process of this test is recognised by its start time`() {
    let pid = ProcessInfo.processInfo.processIdentifier
    let witness = processStartTime(of: pid)

    #expect(witness != nil)
    #expect(processMatches(pid: pid, startedAt: witness))
    #expect(processMatches(pid: pid, startedAt: witness.map { $0 - 1 }) == false)
    #expect(processMatches(pid: pid, startedAt: nil) == false)
  }

  private func managedRun(
    project: UUIDV7,
    name: String,
    pid: Int,
    startedAt: Int64? = 1
  ) -> AppRunRecord {
    AppRunRecord(
      projectID: project,
      name: name,
      ownership: .managed,
      pid: pid,
      processGroupID: pid,
      processStartedAt: startedAt
    )
  }

  private func insertProject(in database: any DatabaseWriter) throws -> UUIDV7 {
    let project = ProjectRecord(rootPath: "/tmp/\(UUID().uuidString)", name: "demo")
    try database.write { db in try ProjectRecord.insert { project }.execute(db) }
    return project.id
  }

  private func memoryDatabase() throws -> any DatabaseWriter {
    try openTailregDatabase(path: ":memory:", kind: .queue)
  }
}
