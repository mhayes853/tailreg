import Foundation
import SQLiteData
import Testing
import UUIDV7

@testable import TailregCore

@Suite(.timeLimit(.minutes(1)))
struct `External process log monitor tests` {
  @Test
  func `Discovers And Persists Redirected Standard Output And Error For A Listener Process`() async throws {
    let temp = try TempDirectory()
    let fixture = try LogWritingSocketProcess(in: temp.url)
    defer { fixture.stop() }
    let process = try await listenerProcess(for: fixture)

    let output = await process.output()
    #expect(output.standardOutput.file?.url == fixture.standardOutputURL)
    #expect(output.standardError.file?.url == fixture.standardErrorURL)

    let database = try openTailregDatabase(path: temp.path("tailreg.sqlite"), kind: .queue)
    let bindingID = try await binding(into: database)
    let monitor = ProcessLogMonitor(database: database, batchSize: 1)
    let task = Task { try await monitor.monitor(output, for: bindingID) }
    defer {
      task.cancel()
    }

    // The follower starts from the current end. Give it time to open both files before emission.
    try await Task.sleep(for: .milliseconds(100))
    try fixture.emit()

    let records = try await eventually {
      try await database.read { db in
        try LogRecord.page(for: bindingID, limit: 10).fetchAll(db)
      }
    } until: { records in
      Set(records.map { [$0.stream.rawValue, $0.message] })
        == [["stdout", "fixture stdout"], ["stderr", "fixture stderr"]]
    }
    #expect(records.count == 2)
  }

  @Test
  func `Follows A Shared Redirected Output File Only Once`() async throws {
    let temp = try TempDirectory()
    let fixture = try LogWritingSocketProcess(in: temp.url, mergedOutput: true)
    defer { fixture.stop() }
    let output = await (try await listenerProcess(for: fixture)).output()
    #expect(output.standardOutput.file?.identity == output.standardError.file?.identity)

    let database = try openTailregDatabase(path: temp.path("tailreg.sqlite"), kind: .queue)
    let bindingID = try await binding(into: database)
    let task = Task {
      try await ProcessLogMonitor(database: database, batchSize: 1).monitor(output, for: bindingID)
    }
    defer { task.cancel() }

    try await Task.sleep(for: .milliseconds(100))
    try fixture.emit()

    let records = try await eventually {
      try await database.read { db in
        try LogRecord.page(for: bindingID, limit: 10).fetchAll(db)
      }
    } until: { $0.count == 2 }
    #expect(records.map(\.message).sorted() == ["fixture stderr", "fixture stdout"])
    #expect(records.allSatisfy { $0.stream == .standardOutput })
  }

  @Test
  func `Reports Null Device Output As Unavailable`() async throws {
    let fixture = try SocketHoldingProcess()
    defer { fixture.stop() }
    let port = fixture.port
    let pid = fixture.pid
    let matches = try await eventually(
      { try await SystemListeningProcessLocator().processes(listeningOn: port) },
      until: { $0.contains { $0.pid == pid } }
    )
    let process = matches.first { $0.pid == pid }
    #expect(process != nil)
    let output = await process?.output()
    #expect(output?.standardOutput == .unavailable(.nullDevice))
    #expect(output?.standardError == .unavailable(.nullDevice))
  }

  @Test
  func `Reports Pipe Output As Unavailable`() async throws {
    let fixture = try SocketHoldingProcess(output: .pipe)
    defer { fixture.stop() }
    let process = try await listenerProcess(for: fixture.port, pid: fixture.pid)

    let output = await process.output()
    #expect(output.standardOutput == .unavailable(.pipe))
    #expect(output.standardError == .unavailable(.pipe))
  }

  private func listenerProcess(for fixture: LogWritingSocketProcess) async throws -> ListeningProcess {
    try await listenerProcess(for: fixture.port, pid: fixture.pid)
  }

  private func listenerProcess(for port: PortNumber, pid: Int32) async throws -> ListeningProcess {
    let matches = try await eventually(
      { try await SystemListeningProcessLocator().processes(listeningOn: port) },
      until: { $0.contains { $0.pid == pid } }
    )
    return try #require(matches.first { $0.pid == pid })
  }

  private func binding(into database: any DatabaseWriter) async throws -> UUIDV7 {
    let record = TailscaleBindingRecord(
      hostname: "node.example.ts.net",
      localPort: 3000,
      tailnetPort: 443,
      proto: .https,
      mountPath: "/",
      status: .active,
      createdAt: .now
    )
    try await database.write { db in
      try TailscaleBindingRecord.insert { record }.execute(db)
    }
    return record.id
  }

  private func eventually<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value,
    until predicate: @escaping @Sendable (Value) -> Bool
  ) async throws -> Value {
    for _ in 0..<100 {
      let value = try await operation()
      if predicate(value) { return value }
      try await Task.sleep(for: .milliseconds(25))
    }
    return try await operation()
  }
}

private extension ProcessOutputTarget {
  var file: ProcessOutputFile? {
    guard case let .regularFile(file) = self else { return nil }
    return file
  }
}
