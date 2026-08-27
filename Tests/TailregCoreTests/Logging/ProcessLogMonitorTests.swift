import Clocks
import Foundation
import SQLiteData
import Testing
import UUIDV7

@testable import TailregCore

@Suite(.timeLimit(.minutes(1)))
struct `Process log monitor tests` {
  private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

  private func database(_ temp: TempDirectory) throws -> any DatabaseWriter {
    try openTailregDatabase(path: temp.path("tailreg.sqlite"), kind: .queue)
  }

  private func binding(into database: any DatabaseWriter) async throws -> UUIDV7 {
    let record = TailscaleBindingRecord(
      hostname: "node.example.ts.net",
      localPort: 3000,
      tailnetPort: 443,
      proto: .https,
      mountPath: "/",
      status: .active,
      createdAt: Self.stamp
    )
    try await database.write { db in
      try TailscaleBindingRecord.insert { record }.execute(db)
    }
    return record.id
  }

  private func line(_ message: String) -> LogLine {
    LogLine(stream: .standardOutput, message: message, at: Self.stamp)
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
  func `Flushes A Full Batch Without Waiting For The Interval`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    let (output, lines) = AsyncStream.makeStream(of: LogLine.self)
    let (batches, reported) = AsyncStream.makeStream(of: [LogLine].self)
    let monitor = ProcessLogMonitor(database: database, batchSize: 3, clock: TestClock())

    let task = Task {
      try await monitor.monitor(output, for: bindingID) { reported.yield($0) }
    }
    for message in ["a", "b", "c"] {
      lines.yield(line(message))
    }

    var iterator = batches.makeAsyncIterator()
    #expect(await iterator.next()?.map(\.message) == ["a", "b", "c"])
    #expect(try await messages(for: bindingID, in: database) == ["a", "b", "c"])

    lines.finish()
    try await task.value
  }

  @Test
  func `Flushes A Partial Batch When The Interval Elapses`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    let clock = TestClock()
    let (output, lines) = AsyncStream.makeStream(of: LogLine.self)
    let (batches, reported) = AsyncStream.makeStream(of: [LogLine].self)
    let monitor = ProcessLogMonitor(
      database: database,
      batchSize: 1000,
      flushInterval: .milliseconds(250),
      clock: clock
    )

    let task = Task {
      try await monitor.monitor(output, for: bindingID) { reported.yield($0) }
    }
    lines.yield(line("lonely"))

    let ticker = Task {
      while !Task.isCancelled {
        await clock.advance(by: .milliseconds(250))
        await Task.yield()
      }
    }
    var iterator = batches.makeAsyncIterator()
    #expect(await iterator.next()?.map(\.message) == ["lonely"])
    ticker.cancel()

    #expect(try await messages(for: bindingID, in: database) == ["lonely"])

    lines.finish()
    try await task.value
  }

  @Test
  func `Writes The Final Partial Batch When The Stream Finishes`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    let (output, lines) = AsyncStream.makeStream(of: LogLine.self)
    let monitor = ProcessLogMonitor(database: database, batchSize: 1000, clock: TestClock())

    let task = Task { try await monitor.monitor(output, for: bindingID) }
    lines.yield(line("a"))
    lines.yield(line("b"))
    lines.finish()
    try await task.value

    #expect(try await messages(for: bindingID, in: database) == ["a", "b"])
  }

  @Test
  func `Appends Successive Batches In Order`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    let (output, lines) = AsyncStream.makeStream(of: LogLine.self)
    let (batches, reported) = AsyncStream.makeStream(of: [LogLine].self)
    let monitor = ProcessLogMonitor(database: database, batchSize: 2, clock: TestClock())

    let task = Task {
      try await monitor.monitor(output, for: bindingID) { reported.yield($0) }
    }
    var iterator = batches.makeAsyncIterator()

    for message in ["a", "b"] { lines.yield(line(message)) }
    _ = await iterator.next()
    for message in ["c", "d"] { lines.yield(line(message)) }
    _ = await iterator.next()

    lines.finish()
    try await task.value

    #expect(try await messages(for: bindingID, in: database) == ["a", "b", "c", "d"])
  }

  @Test
  func `An Empty Stream Writes Nothing`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    let (output, lines) = AsyncStream.makeStream(of: LogLine.self)
    let monitor = ProcessLogMonitor(database: database, clock: TestClock())

    let task = Task { try await monitor.monitor(output, for: bindingID) }
    lines.finish()
    try await task.value

    #expect(try await messages(for: bindingID, in: database).isEmpty)
  }

  @Test
  func `Records Both Process Streams Against A Binding`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    let out = Pipe()
    let err = Pipe()
    let monitor = ProcessLogMonitor(database: database, batchSize: 2, clock: TestClock())

    let task = Task {
      try await monitor.monitor(
        standardOutput: out.fileHandleForReading,
        standardError: err.fileHandleForReading,
        for: bindingID
      )
    }
    try out.fileHandleForWriting.write(contentsOf: Data("ready\nserving\n".utf8))
    try err.fileHandleForWriting.write(contentsOf: Data("warning\n".utf8))
    try out.fileHandleForWriting.close()
    try err.fileHandleForWriting.close()
    try await task.value

    let records = try await database.read { db in
      try LogRecord.page(for: bindingID).fetchAll(db)
    }
    #expect(records.count == 3)
    #expect(
      Set(records.map { [$0.stream.rawValue, $0.message] })
        == [["stdout", "ready"], ["stdout", "serving"], ["stderr", "warning"]]
    )
  }

  @Test
  func `Closes Both Handles Once Both Streams Finish`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    let out = Pipe()
    let err = Pipe()
    let outHandle = out.fileHandleForReading
    let errHandle = err.fileHandleForReading
    let monitor = ProcessLogMonitor(database: database, clock: TestClock())

    let task = Task {
      try await monitor.monitor(
        standardOutput: outHandle,
        standardError: errHandle,
        for: bindingID
      )
    }
    try out.fileHandleForWriting.close()
    try err.fileHandleForWriting.close()
    try await task.value

    #expect(outHandle.fileDescriptor == -1)
    #expect(errHandle.fileDescriptor == -1)
  }

  @Test
  func `Records A Pipes Output Against A Binding`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let bindingID = try await binding(into: database)

    let pipe = Pipe()
    let output = processOutputLines(
      pipe.fileHandleForReading,
      as: .standardOutput,
      now: { Self.stamp }
    )
    let monitor = ProcessLogMonitor(database: database, batchSize: 2, clock: TestClock())

    let task = Task { try await monitor.monitor(output, for: bindingID) }
    try pipe.fileHandleForWriting.write(contentsOf: Data("ready\nlistening\nserving\n".utf8))
    try pipe.fileHandleForWriting.close()
    try await task.value

    let records = try await database.read { db in
      try LogRecord.page(for: bindingID).fetchAll(db)
    }
    #expect(records.map(\.message) == ["ready", "listening", "serving"])
    #expect(records.allSatisfy { $0.stream == .standardOutput })
    #expect(records.allSatisfy { $0.at == Self.stamp })
  }
}
