import Foundation
import SQLiteData
import Testing
import UUIDV7

@testable import TailregCore

@Suite
struct `Tailreg database schema tests` {
  private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

  private func record(
    localPort: Int,
    tailnetPort: Int,
    proto: TailscaleServeProtocol = .https,
    mountPath: String = "/",
    status: TailscaleBindingStatus = .active,
    createdAt: Date = epoch,
    endedAt: Date? = nil,
    endReason: TailscaleBindingEndReason? = nil
  ) -> TailscaleBindingRecord {
    TailscaleBindingRecord(
      hostname: "node.example.ts.net",
      localPort: localPort,
      tailnetPort: tailnetPort,
      proto: proto,
      mountPath: mountPath,
      status: status,
      createdAt: createdAt,
      endedAt: endedAt,
      endReason: endReason
    )
  }

  private func insert(
    _ record: TailscaleBindingRecord,
    into database: any DatabaseWriter
  ) async throws {
    try await database.write { db in
      try TailscaleBindingRecord.insert { record }.execute(db)
    }
  }

  private func end(
    _ record: TailscaleBindingRecord,
    reason: TailscaleBindingEndReason = .unbound,
    at date: Date = epoch.addingTimeInterval(60),
    in database: any DatabaseWriter
  ) async throws {
    try await database.write { db in
      try TailscaleBindingRecord
        .where { $0.id.eq(record.id) }
        .update {
          $0.status = #bind(TailscaleBindingStatus.ended)
          $0.endedAt = #bind(date)
          $0.endReason = #bind(reason)
        }
        .execute(db)
    }
  }

  private func all(_ database: any DatabaseWriter) async throws -> [TailscaleBindingRecord] {
    try await database.read { db in
      try TailscaleBindingRecord
        .order { ($0.tailnetPort, $0.mountPath, $0.createdAt) }
        .fetchAll(db)
    }
  }

  private func live(_ database: any DatabaseWriter) async throws -> [TailscaleBindingRecord] {
    try await all(database).filter(\.isLive)
  }

  private func database(_ temp: TempDirectory) throws -> any DatabaseWriter {
    try openTailregDatabase(path: temp.path("tailreg.sqlite"), kind: .queue)
  }

  @Test
  func `Round Trips A Binding`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    let written = record(localPort: 3000, tailnetPort: 443)
    try await insert(written, into: database)

    #expect(try await all(database) == [written])
  }

  @Test
  func `Assigns A Time Ordered Identifier To Each Binding`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    try await insert(record(localPort: 3000, tailnetPort: 443), into: database)
    try await insert(record(localPort: 4000, tailnetPort: 8443), into: database)

    let ids = try await all(database).map(\.id)
    #expect(Set(ids).count == 2)
    #expect(ids == ids.sorted())
  }

  @Test
  func `Treats Mount Path And Protocol As Part Of The Handler`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    try await insert(record(localPort: 3000, tailnetPort: 443), into: database)
    try await insert(record(localPort: 4000, tailnetPort: 443, mountPath: "/api"), into: database)
    try await insert(record(localPort: 5000, tailnetPort: 443, proto: .tcp), into: database)

    #expect(try await all(database).count == 3)
  }

  @Test
  func `Refuses A Second Live Binding For The Same Handler`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    try await insert(record(localPort: 3000, tailnetPort: 443), into: database)

    await #expect(throws: (any Error).self) {
      try await insert(record(localPort: 4000, tailnetPort: 443), into: database)
    }
  }

  @Test
  func `Serves The Same Handler Again Once The Earlier Binding Ended`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    let first = record(localPort: 3000, tailnetPort: 443)
    try await insert(first, into: database)
    try await end(first, in: database)

    try await insert(
      record(localPort: 4000, tailnetPort: 443, createdAt: Self.epoch.addingTimeInterval(120)),
      into: database
    )

    let records = try await all(database)
    #expect(records.count == 2)
    #expect(records.map(\.localPort) == [3000, 4000])
    #expect(try await live(database).map(\.localPort) == [4000])
  }

  @Test
  func `Ending A Binding Keeps It On File With Its Reason`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    let written = record(localPort: 3000, tailnetPort: 443)
    try await insert(written, into: database)
    try await end(written, reason: .expired, in: database)

    let stored = try #require(try await all(database).first)
    #expect(stored.id == written.id)
    #expect(stored.status == .ended)
    #expect(stored.endReason == .expired)
    #expect(stored.endedAt == Self.epoch.addingTimeInterval(60))
    #expect(stored.isLive == false)
  }

  @Test
  func `Ending One Binding Leaves Its Neighbours Live`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    let doomed = record(localPort: 3000, tailnetPort: 443)
    try await insert(doomed, into: database)
    try await insert(record(localPort: 4000, tailnetPort: 8443), into: database)

    try await end(doomed, in: database)

    #expect(try await live(database).map(\.tailnetPort) == [8443])
    #expect(try await all(database).count == 2)
  }

  @Test
  func `Keeps A Pending Binding Out Of The Way Of A Second Claim`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    try await insert(record(localPort: 3000, tailnetPort: 443, status: .pending), into: database)

    await #expect(throws: (any Error).self) {
      try await insert(record(localPort: 4000, tailnetPort: 443), into: database)
    }
  }

  @Test
  func `Rejects A Binding The Schema Considers Impossible`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    await #expect(throws: (any Error).self) {
      try await insert(record(localPort: 3000, tailnetPort: 70000), into: database)
    }
  }

  @Test
  func `Rejects An End Date Without A Reason`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    await #expect(throws: (any Error).self) {
      try await insert(
        record(
          localPort: 3000,
          tailnetPort: 443,
          status: .ended,
          endedAt: Self.epoch.addingTimeInterval(60)
        ),
        into: database
      )
    }
  }

  @Test
  func `Rejects A Live Binding That Claims To Have Ended`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    await #expect(throws: (any Error).self) {
      try await insert(
        record(
          localPort: 3000,
          tailnetPort: 443,
          status: .active,
          endedAt: Self.epoch.addingTimeInterval(60),
          endReason: .unbound
        ),
        into: database
      )
    }
  }

  @Test
  func `Rejects An Ended Binding With No End Date`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    await #expect(throws: (any Error).self) {
      try await insert(
        record(localPort: 3000, tailnetPort: 443, status: .ended),
        into: database
      )
    }
  }

  @Test
  func `A Second Connection Sees Committed Bindings`() async throws {
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
  func `Migrating An Existing Database Again Is A No Op`() async throws {
    let temp = try TempDirectory()
    let path = temp.path("tailreg.sqlite")

    let first = try openTailregDatabase(path: path, kind: .queue)
    try await insert(record(localPort: 3000, tailnetPort: 443), into: first)

    let second = try openTailregDatabase(path: path, kind: .queue)
    #expect(try await all(second).map(\.tailnetPort) == [443])
  }
}
