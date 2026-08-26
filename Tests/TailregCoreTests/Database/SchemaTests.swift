import Foundation
import SQLiteData
import Testing
import UUIDV7

@testable import TailregCore

@Suite
struct `Tailreg database schema tests` {
  private func record(
    localPort: Int,
    tailnetPort: Int,
    proto: TailscaleServeProtocol = .https,
    mountPath: String = "/",
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> TailscaleBindingRecord {
    TailscaleBindingRecord(
      localPort: localPort,
      tailnetPort: tailnetPort,
      proto: proto,
      mountPath: mountPath,
      createdAt: createdAt
    )
  }

  private func insert(
    _ record: TailscaleBindingRecord,
    into database: any DatabaseWriter
  ) async throws {
    try await database.write { db in
      try TailscaleBindingRecord
        .insert {
          record
        } onConflict: {
          ($0.tailnetPort, $0.proto, $0.mountPath)
        } doUpdate: { updates, excluded in
          updates.localPort = excluded.localPort
          updates.createdAt = excluded.createdAt
        }
        .execute(db)
    }
  }

  private func all(_ database: any DatabaseWriter) async throws -> [TailscaleBindingRecord] {
    try await database.read { db in
      try TailscaleBindingRecord.order { ($0.tailnetPort, $0.mountPath) }.fetchAll(db)
    }
  }

  @Test
  func `Round Trips A Claim`() async throws {
    let temp = try TempDirectory()
    let database = try openTailregDatabase(path: temp.path("tailreg.sqlite"), kind: .queue)

    let written = record(localPort: 3000, tailnetPort: 443)
    try await insert(written, into: database)

    #expect(try await all(database) == [written])
  }

  @Test
  func `Assigns A Time Ordered Identifier To Each Claim`() async throws {
    let temp = try TempDirectory()
    let database = try openTailregDatabase(path: temp.path("tailreg.sqlite"), kind: .queue)

    try await insert(record(localPort: 3000, tailnetPort: 443), into: database)
    try await insert(record(localPort: 4000, tailnetPort: 8443), into: database)

    let ids = try await all(database).map(\.id)
    #expect(Set(ids).count == 2)
    #expect(ids == ids.sorted())
  }

  @Test
  func `Reclaiming The Same Handler Replaces The Row Rather Than Duplicating It`() async throws {
    let temp = try TempDirectory()
    let database = try openTailregDatabase(path: temp.path("tailreg.sqlite"), kind: .queue)

    try await insert(record(localPort: 3000, tailnetPort: 443), into: database)
    let original = try #require(try await all(database).first)

    try await insert(
      record(
        localPort: 4000,
        tailnetPort: 443,
        createdAt: Date(timeIntervalSince1970: 1_700_000_500)
      ),
      into: database
    )

    let records = try await all(database)
    #expect(records.count == 1)
    #expect(records.first?.localPort == 4000)
    #expect(records.first?.id == original.id)
  }

  @Test
  func `Treats Mount Path And Protocol As Part Of The Claim`() async throws {
    let temp = try TempDirectory()
    let database = try openTailregDatabase(path: temp.path("tailreg.sqlite"), kind: .queue)

    try await insert(record(localPort: 3000, tailnetPort: 443), into: database)
    try await insert(record(localPort: 4000, tailnetPort: 443, mountPath: "/api"), into: database)
    try await insert(record(localPort: 5000, tailnetPort: 443, proto: .tcp), into: database)

    #expect(try await all(database).count == 3)
  }

  @Test
  func `Deleting By Identifier Leaves Neighbours Alone`() async throws {
    let temp = try TempDirectory()
    let database = try openTailregDatabase(path: temp.path("tailreg.sqlite"), kind: .queue)

    try await insert(record(localPort: 3000, tailnetPort: 443), into: database)
    try await insert(record(localPort: 4000, tailnetPort: 8443), into: database)

    let doomed = try #require(try await all(database).first { $0.tailnetPort == 443 })
    try await database.write { db in
      try TailscaleBindingRecord.find([doomed.id]).delete().execute(db)
    }

    #expect(try await all(database).map(\.tailnetPort) == [8443])
  }

  @Test
  func `A Second Connection Sees Committed Claims`() async throws {
    let temp = try TempDirectory()
    let path = temp.path("tailreg.sqlite")
    let daemon = try openTailregDatabase(path: path)
    let cli = try openTailregDatabase(path: path)

    try await insert(record(localPort: 3000, tailnetPort: 443), into: daemon)

    #expect(try await all(cli).map(\.tailnetPort) == [443])
  }

  @Test
  func `Interleaved Writers Do Not Clobber Each Other`() async throws {
    let temp = try TempDirectory()
    let path = temp.path("tailreg.sqlite")
    let daemon = try openTailregDatabase(path: path)
    let cli = try openTailregDatabase(path: path)

    async let first: Void = insert(record(localPort: 3000, tailnetPort: 443), into: daemon)
    async let second: Void = insert(record(localPort: 4000, tailnetPort: 8443), into: cli)
    _ = try await (first, second)

    #expect(try await all(daemon).map(\.tailnetPort) == [443, 8443])
  }

  @Test
  func `Rejects A Claim The Schema Considers Impossible`() async throws {
    let temp = try TempDirectory()
    let database = try openTailregDatabase(path: temp.path("tailreg.sqlite"), kind: .queue)

    await #expect(throws: (any Error).self) {
      try await insert(record(localPort: 3000, tailnetPort: 70000), into: database)
    }
  }

  @Test
  func `Migrating An Existing Database Again Is A No Op`() async throws {
    let temp = try TempDirectory()
    let path = temp.path("tailreg.sqlite")

    let first = try openTailregDatabase(path: path, kind: .queue)
    try await insert(record(localPort: 3000, tailnetPort: 443), into: first)

    let second = try openTailregDatabase(path: path, kind: .queue)
    #expect(try await all(second).map(\.tailnetPort) == [443])
  }
}
