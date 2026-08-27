import Foundation
import SQLiteData
import Testing
import UUIDV7

@testable import TailregCore

@Suite
struct `Log query tests` {
  private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

  private func database(_ temp: TempDirectory) throws -> any DatabaseWriter {
    try openTailregDatabase(path: temp.path("tailreg.sqlite"), kind: .queue)
  }

  private func binding(
    tailnetPort: Int = 443,
    endedAt: Date? = nil,
    into database: any DatabaseWriter
  ) async throws -> UUIDV7 {
    let record = TailscaleBindingRecord(
      hostname: "node.example.ts.net",
      localPort: 3000,
      tailnetPort: tailnetPort,
      proto: .https,
      mountPath: "/",
      status: endedAt == nil ? .active : .ended,
      createdAt: Self.epoch,
      endedAt: endedAt,
      endReason: endedAt == nil ? nil : .unbound
    )
    try await database.write { db in
      try TailscaleBindingRecord.insert { record }.execute(db)
    }
    return record.id
  }

  private func lines(
    _ messages: [String],
    stream: ProcessStream = .standardOutput
  ) -> [LogLine] {
    messages.enumerated()
      .map { offset, message in
        LogLine(
          stream: stream,
          message: message,
          at: Self.epoch.addingTimeInterval(TimeInterval(offset))
        )
      }
  }

  private func append(
    _ messages: [String],
    stream: ProcessStream = .standardOutput,
    for bindingID: UUIDV7,
    into database: any DatabaseWriter
  ) async throws {
    try await database.write { db in
      try LogRecord.append(lines(messages, stream: stream), for: bindingID, in: db)
    }
  }

  private func messages(
    for bindingID: UUIDV7,
    in database: any DatabaseWriter
  ) async throws -> [String] {
    try await database.read { db in
      try LogRecord.page(for: bindingID, limit: 10_000).fetchAll(db).map(\.message)
    }
  }

  @Test
  func `Appends A Batch And Reads It Back In Order`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    try await append(["one", "two", "three"], for: bindingID, into: database)

    #expect(try await messages(for: bindingID, in: database) == ["one", "two", "three"])
  }

  @Test
  func `Preserves Arrival Order Across Separate Appends`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    try await append(["one", "two"], for: bindingID, into: database)
    try await append(["three"], for: bindingID, into: database)
    try await append(["four", "five"], for: bindingID, into: database)

    #expect(
      try await messages(for: bindingID, in: database) == [
        "one", "two", "three", "four", "five"
      ]
    )
  }

  @Test
  func `Keeps Two Bindings Logs Independent`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let first = try await binding(tailnetPort: 443, into: database)
    let second = try await binding(tailnetPort: 8443, into: database)

    try await append(["alpha"], for: first, into: database)
    try await append(["beta", "gamma"], for: second, into: database)

    #expect(try await messages(for: first, in: database) == ["alpha"])
    #expect(try await messages(for: second, in: database) == ["beta", "gamma"])
  }

  @Test
  func `Appending Nothing Is A No Op`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    let written = try await database.write { db in
      try LogRecord.append([], for: bindingID, in: db)
    }

    #expect(written == 0)
    #expect(try await messages(for: bindingID, in: database).isEmpty)
  }

  @Test
  func `Records Which Stream A Line Came From`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    try await append(["out"], stream: .standardOutput, for: bindingID, into: database)
    try await append(["err"], stream: .standardError, for: bindingID, into: database)

    let records = try await database.read { db in
      try LogRecord.page(for: bindingID).fetchAll(db)
    }
    #expect(records.map(\.stream) == [.standardOutput, .standardError])
  }

  @Test
  func `Rejects A Log For A Binding That Does Not Exist`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)

    let reported = await #expect(throws: DatabaseError.self) {
      try await database.write { db in
        try LogRecord.append(lines(["orphan"]), for: UUIDV7(), in: db)
      }
    }
    #expect(reported?.resultCode == .SQLITE_CONSTRAINT)
    #expect(reported?.message?.contains("FOREIGN KEY") == true)
  }

  @Test
  func `Rejects A Stream The Schema Does Not Know`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    let reported = await #expect(throws: DatabaseError.self) {
      try await database.write { db in
        try #sql(
          """
          INSERT INTO "logs" ("id", "bindingID", "stream", "message", "at")
          VALUES (\(bind: UUIDV7()), \(bind: bindingID), 'stdin', 'nope', '2023-11-14')
          """
        )
        .execute(db)
      }
    }
    #expect(reported?.resultCode == .SQLITE_CONSTRAINT)
    #expect(reported?.message?.contains("CHECK") == true)
  }

  @Test
  func `Preserves A Message Verbatim`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    let awkward = [
      "\u{1B}[32mready\u{1B}[0m in 412 ms",
      "→ Local: http://localhost:3000/",
      "",
      "  indented\ttabbed  ",
      "emoji 🚀 and ümlaut"
    ]
    try await append(awkward, for: bindingID, into: database)

    #expect(try await messages(for: bindingID, in: database) == awkward)
  }

  @Test
  func `Pages Forward Through A Cursor`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)
    try await append(["a", "b", "c", "d", "e"], for: bindingID, into: database)

    var seen: [String] = []
    var cursor: UUIDV7?
    while true {
      let after = cursor
      let page = try await database.read { db in
        try LogRecord.page(for: bindingID, after: after, limit: 2).fetchAll(db)
      }
      guard !page.isEmpty else { break }
      seen.append(contentsOf: page.map(\.message))
      cursor = page.last?.id
    }

    #expect(seen == ["a", "b", "c", "d", "e"])
  }

  @Test
  func `Paging Past The End Yields Nothing`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)
    try await append(["a", "b"], for: bindingID, into: database)

    let last = try await database.read { db in
      try LogRecord.tail(for: bindingID, limit: 1).fetchAll(db)
    }
    let beyond = try await database.read { db in
      try LogRecord.page(for: bindingID, after: last[0].id).fetchAll(db)
    }

    #expect(beyond.isEmpty)
  }

  @Test
  func `Tails The Most Recent Lines`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)
    try await append(["a", "b", "c", "d", "e"], for: bindingID, into: database)

    let tail = try await database.read { db in
      try LogRecord.tail(for: bindingID, limit: 2).fetchAll(db)
    }

    #expect(tail.map(\.message).reversed() == ["d", "e"])
  }

  @Test
  func `Tails An Earlier Page Through An Offset`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)
    try await append(["a", "b", "c", "d", "e"], for: bindingID, into: database)

    let tail = try await database.read { db in
      try LogRecord.tail(for: bindingID, limit: 2, offset: 2).fetchAll(db)
    }

    #expect(tail.map(\.message).reversed() == ["b", "c"])
  }

  @Test
  func `Tailing Past The End Yields Nothing`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)
    try await append(["a", "b"], for: bindingID, into: database)

    let tail = try await database.read { db in
      try LogRecord.tail(for: bindingID, limit: 5, offset: 10).fetchAll(db)
    }

    #expect(tail.isEmpty)
  }

  @Test
  func `Keeps Only The Last Lines When Pruned`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)
    try await append(["a", "b", "c", "d", "e"], for: bindingID, into: database)

    let removed = try await database.write { db in
      try LogRecord.prune(for: bindingID, keepingLast: 2, in: db)
    }

    #expect(removed == 3)
    #expect(try await messages(for: bindingID, in: database) == ["d", "e"])
  }

  @Test
  func `Pruning Below The Line Count Removes Nothing`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)
    try await append(["a", "b"], for: bindingID, into: database)

    let removed = try await database.write { db in
      try LogRecord.prune(for: bindingID, keepingLast: 10, in: db)
    }

    #expect(removed == 0)
    #expect(try await messages(for: bindingID, in: database) == ["a", "b"])
  }

  @Test
  func `Pruning To Zero Clears The Binding`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)
    try await append(["a", "b", "c"], for: bindingID, into: database)

    let removed = try await database.write { db in
      try LogRecord.prune(for: bindingID, keepingLast: 0, in: db)
    }

    #expect(removed == 3)
    #expect(try await messages(for: bindingID, in: database).isEmpty)
  }

  @Test
  func `Pruning One Binding Leaves The Others Alone`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let first = try await binding(tailnetPort: 443, into: database)
    let second = try await binding(tailnetPort: 8443, into: database)
    try await append(["a", "b", "c"], for: first, into: database)
    try await append(["x", "y", "z"], for: second, into: database)

    try await database.write { db in
      try LogRecord.prune(for: first, keepingLast: 1, in: db)
    }

    #expect(try await messages(for: first, in: database) == ["c"])
    #expect(try await messages(for: second, in: database) == ["x", "y", "z"])
  }

  @Test
  func `Drops Logs For Bindings Ended Before A Date`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let old = try await binding(
      tailnetPort: 443,
      endedAt: Self.epoch.addingTimeInterval(-3600),
      into: database
    )
    let recent = try await binding(
      tailnetPort: 8443,
      endedAt: Self.epoch.addingTimeInterval(3600),
      into: database
    )
    try await append(["stale"], for: old, into: database)
    try await append(["fresh"], for: recent, into: database)

    let removed = try await database.write { db in
      try LogRecord.prune(endedBefore: Self.epoch, in: db)
    }

    #expect(removed == 1)
    #expect(try await messages(for: old, in: database).isEmpty)
    #expect(try await messages(for: recent, in: database) == ["fresh"])
  }

  @Test
  func `Leaves A Live Bindings Logs Alone When Pruning By Date`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)
    try await append(["running"], for: bindingID, into: database)

    let removed = try await database.write { db in
      try LogRecord.prune(endedBefore: Self.epoch.addingTimeInterval(86_400), in: db)
    }

    #expect(removed == 0)
    #expect(try await messages(for: bindingID, in: database) == ["running"])
  }

  @Test
  func `Appends And Prunes In One Transaction`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)
    try await append(["a", "b"], for: bindingID, into: database)

    try await database.write { db in
      try LogRecord.append(lines(["c", "d"]), for: bindingID, in: db)
      try LogRecord.prune(for: bindingID, keepingLast: 3, in: db)
    }

    #expect(try await messages(for: bindingID, in: database) == ["b", "c", "d"])
  }

  @Test
  func `Removes Logs When Their Binding Is Deleted`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)
    try await append(["a", "b"], for: bindingID, into: database)

    try await database.write { db in
      try TailscaleBindingRecord.find([bindingID]).delete().execute(db)
    }

    #expect(try await messages(for: bindingID, in: database).isEmpty)
  }
}
