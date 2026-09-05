import Foundation
import SQLiteData
import TailregTestSupport
import Testing
import UUIDV7

@testable import TailregCore

/// The three ways a binding's end state can contradict itself.
///
/// The schema forbids each of them, so nothing reading a binding back ever has to decide which
/// of `status`, `endedAt` and `endReason` to believe.
enum ImpossibleEnding: CaseIterable {
  case endDateWithoutReason
  case liveButEnded
  case endedWithoutDate
}

@Suite
struct `Tailreg database schema tests` {
  private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

  private func record(
    localPort: PortNumber,
    tailnetPort: PortNumber,
    proto: TailscaleServeProtocol = .https,
    mountPath: String = "/",
    status: TailscaleBindingStatus = .active,
    createdAt: Date = epoch,
    endedAt: Date? = nil,
    endReason: TailscaleBindingEndReason? = nil
  ) -> TailscaleBindingRecord {
    .fixture(
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

  @Test
  func `Round Trips A Binding`() async throws {
    let database = try TestDatabase.inMemory()

    let written = record(localPort: .fixed(3000), tailnetPort: .fixed(443))
    try await insert(written, into: database)

    #expect(try await all(database) == [written])
  }

  @Test
  func `Assigns A Time Ordered Identifier To Each Binding`() async throws {
    let database = try TestDatabase.inMemory()

    try await insert(record(localPort: .fixed(3000), tailnetPort: .fixed(443)), into: database)
    try await insert(record(localPort: .fixed(4000), tailnetPort: .fixed(8443)), into: database)

    let ids = try await all(database).map(\.id)
    #expect(Set(ids).count == 2)
    #expect(ids == ids.sorted())
  }

  @Test
  func `Treats Mount Path And Protocol As Part Of The Handler`() async throws {
    let database = try TestDatabase.inMemory()

    try await insert(record(localPort: .fixed(3000), tailnetPort: .fixed(443)), into: database)
    try await insert(
      record(localPort: .fixed(4000), tailnetPort: .fixed(443), mountPath: "/api"),
      into: database
    )
    try await insert(
      record(localPort: .fixed(5000), tailnetPort: .fixed(443), proto: .tcp),
      into: database
    )

    #expect(try await all(database).count == 3)
  }

  @Test
  func `Refuses A Second Live Binding For The Same Handler`() async throws {
    let database = try TestDatabase.inMemory()

    try await insert(record(localPort: .fixed(3000), tailnetPort: .fixed(443)), into: database)

    await #expect(throws: (any Error).self) {
      try await insert(record(localPort: .fixed(4000), tailnetPort: .fixed(443)), into: database)
    }
  }

  @Test
  func `Serves The Same Handler Again Once The Earlier Binding Ended`() async throws {
    let database = try TestDatabase.inMemory()

    let first = record(localPort: .fixed(3000), tailnetPort: .fixed(443))
    try await insert(first, into: database)
    try await end(first, in: database)

    try await insert(
      record(
        localPort: .fixed(4000),
        tailnetPort: .fixed(443),
        createdAt: Self.epoch.addingTimeInterval(120)
      ),
      into: database
    )

    let records = try await all(database)
    #expect(records.count == 2)
    #expect(records.map(\.localPort) == [.fixed(3000), .fixed(4000)])
    #expect(try await live(database).map(\.localPort) == [.fixed(4000)])
  }

  @Test
  func `Ending A Binding Keeps It On File With Its Reason`() async throws {
    let database = try TestDatabase.inMemory()

    let written = record(localPort: .fixed(3000), tailnetPort: .fixed(443))
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
    let database = try TestDatabase.inMemory()

    let doomed = record(localPort: .fixed(3000), tailnetPort: .fixed(443))
    try await insert(doomed, into: database)
    try await insert(record(localPort: .fixed(4000), tailnetPort: .fixed(8443)), into: database)

    try await end(doomed, in: database)

    #expect(try await live(database).map(\.tailnetPort) == [.fixed(8443)])
    #expect(try await all(database).count == 2)
  }

  @Test
  func `Keeps A Pending Binding Out Of The Way Of A Second Claim`() async throws {
    let database = try TestDatabase.inMemory()

    try await insert(
      record(localPort: .fixed(3000), tailnetPort: .fixed(443), status: .pending),
      into: database
    )

    await #expect(throws: (any Error).self) {
      try await insert(record(localPort: .fixed(4000), tailnetPort: .fixed(443)), into: database)
    }
  }

  @Test(arguments: ImpossibleEnding.allCases)
  func `Rejects A Binding Whose End State Contradicts Itself`(
    _ ending: ImpossibleEnding
  ) async throws {
    let database = try TestDatabase.inMemory()
    let ended = Self.epoch.addingTimeInterval(60)
    let impossible =
      switch ending {
      case .endDateWithoutReason:
        record(
          localPort: .fixed(3000),
          tailnetPort: .fixed(443),
          status: .ended,
          endedAt: ended
        )
      case .liveButEnded:
        record(
          localPort: .fixed(3000),
          tailnetPort: .fixed(443),
          status: .active,
          endedAt: ended,
          endReason: .unbound
        )
      case .endedWithoutDate:
        record(localPort: .fixed(3000), tailnetPort: .fixed(443), status: .ended)
      }

    await #expect(throws: (any Error).self) {
      try await insert(impossible, into: database)
    }
  }

  /// The port columns are still range-checked in SQL. `PortNumber` keeps Tailreg from writing an
  /// impossible one, but the database is shared state that other writers can reach.
  @Test
  func `Rejects A Port Number Outside The Sixteen Bit Range`() async throws {
    let database = try TestDatabase.inMemory()

    await #expect(throws: (any Error).self) {
      try await database.write { db in
        try #sql(
          """
          INSERT INTO "bindings"
            ("id", "hostname", "localPort", "tailnetPort", "proto", "mountPath", "status",
             "createdAt")
            VALUES ('impossible', 'node.example.ts.net', 3000, 70000, 'https', '/', 'active',
                    '2023-11-14 22:13:20.000')
          """
        )
        .execute(db)
      }
    }
  }

  /// Ports are stored as the integers they always were, so a `PortNumber` written now is the
  /// same row a build that stored an `Int` wrote.
  @Test
  func `Round Trips Ports Through The Database`() async throws {
    let database = try TestDatabase.inMemory()
    let project = ProjectRecord(rootPath: "/tmp/\(UUID().uuidString)", name: "demo")
    let runtime = MuxRunRecord(
      projectID: project.id,
      pid: 4001,
      ingressPort: .fixed(39_428),
      adminPort: .fixed(39_429)
    )
    let binding = record(localPort: .fixed(39_428), tailnetPort: .fixed(8443))

    try await database.write { db in
      try ProjectRecord.insert { project }.execute(db)
      try MuxRunRecord.insert { runtime }.execute(db)
      try TailscaleBindingRecord.insert { binding }.execute(db)
    }

    let storedRuntime = try await database.read { db in
      try MuxRunRecord.live(for: project.id).fetchOne(db)
    }
    #expect(storedRuntime?.ingressPort == .fixed(39_428))
    #expect(storedRuntime?.adminPort == .fixed(39_429))
    #expect(
      try await database
        .read { db in
          try TailscaleBindingRecord.live(localPort: .fixed(39_428)).fetchAll(db)
        }
        .map(\.tailnetPort) == [.fixed(8443)]
    )
  }

  @Test
  func `A Second Connection Sees Committed Bindings`() async throws {
    let temp = try TempDirectory()
    let daemon = try TestDatabase.onDisk(in: temp, kind: .pool)
    let cli = try TestDatabase.onDisk(in: temp, kind: .pool)

    try await insert(record(localPort: .fixed(3000), tailnetPort: .fixed(443)), into: daemon)

    #expect(try await all(cli).map(\.tailnetPort) == [.fixed(443)])
  }

  @Test
  func `Interleaved Writers Do Not Clobber Each Other`() async throws {
    let temp = try TempDirectory()
    let daemon = try TestDatabase.onDisk(in: temp, kind: .pool)
    let cli = try TestDatabase.onDisk(in: temp, kind: .pool)

    async let first: Void = insert(
      record(localPort: .fixed(3000), tailnetPort: .fixed(443)),
      into: daemon
    )
    async let second: Void = insert(
      record(localPort: .fixed(4000), tailnetPort: .fixed(8443)),
      into: cli
    )
    _ = try await (first, second)

    #expect(try await all(daemon).map(\.tailnetPort) == [.fixed(443), .fixed(8443)])
  }

  @Test
  func `Migrating An Existing Database Again Is A No Op`() async throws {
    let temp = try TempDirectory()

    let first = try TestDatabase.onDisk(in: temp)
    try await insert(record(localPort: .fixed(3000), tailnetPort: .fixed(443)), into: first)

    let second = try TestDatabase.onDisk(in: temp)
    #expect(try await all(second).map(\.tailnetPort) == [.fixed(443)])
  }
}
