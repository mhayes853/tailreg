import Foundation
import Operation
import SQLiteData
import Synchronization
import TailregTestSupport
import Testing
import UUIDV7

@testable import TailregCore

@Suite
struct `Operation recording tests` {
  @Test
  func `Records one row for each operation a command ran`() async throws {
    let database = try TestDatabase.inMemory()

    try await recordingCommandRun("up", in: database) { _ in
      _ = try await #run($succeeds(1))
      _ = try await #run($alsoSucceeds)
    }

    let operations = try await recorded(in: database)
    #expect(operations.map(\.operation).sorted() == ["alsoSucceeds", "succeeds"])
    #expect(operations.allSatisfy { $0.outcome == .complete })
    #expect(operations.allSatisfy { $0.failure == nil })
    #expect(operations.allSatisfy { $0.attempts == 1 })
  }

  @Test
  func `Records an operation run inside another as its child`() async throws {
    let database = try TestDatabase.inMemory()

    try await recordingCommandRun("up", in: database) { _ in
      _ = try await #run($callsAnother)
    }

    let operations = try await recorded(in: database)
    let parent = try #require(operations.first { $0.operation == "callsAnother" })
    let child = try #require(operations.first { $0.operation == "succeeds" })
    #expect(parent.parentID == nil)
    #expect(child.parentID == parent.id)
  }

  @Test
  func `Folds every attempt at one polled operation into a single row`() async throws {
    let database = try TestDatabase.inMemory()
    let counter = AttemptCounter()

    try await recordingCommandRun("up", in: database) { _ in
      _ = try await poll(
        $readyOnAttempt(counter, 4),
        within: .seconds(30),
        delayedBy: .noDelay
      )
    }

    let operations = try await recorded(in: database)
    #expect(operations.count == 1)
    #expect(operations.first?.operation == "readyOnAttempt")
    #expect(operations.first?.attempts == 4)
  }

  @Test
  func `Keeps an operation with children out of the fold`() async throws {
    let database = try TestDatabase.inMemory()

    try await recordingCommandRun("up", in: database) { _ in
      _ = try await #run($callsAnother)
      _ = try await #run($callsAnother)
    }

    // Folding the two parents together would leave the second one's child pointing at a row that
    // no longer exists, which the foreign key would refuse.
    let operations = try await recorded(in: database)
    #expect(operations.filter { $0.operation == "callsAnother" }.count == 2)
    #expect(operations.filter { $0.operation == "succeeds" }.count == 2)
  }

  @Test
  func `Records what an operation failed with, and lets the failure through`() async throws {
    let database = try TestDatabase.inMemory()

    await #expect(throws: RecordedFailure.self) {
      try await recordingCommandRun("up", in: database) { _ in
        _ = try await #run($fails)
      }
    }

    let operations = try await recorded(in: database)
    let failed = try #require(operations.first { $0.operation == "fails" })
    #expect(failed.outcome == .failed)
    #expect(failed.failure?.contains("RecordedFailure") == true)

    let command = try #require(try await commandRun(in: database))
    #expect(command.outcome == .failed)
    #expect(command.failure?.contains("RecordedFailure") == true)
  }

  @Test
  func `Completes the command run and attaches the project it turned out to be about`()
    async throws
  {
    let database = try TestDatabase.inMemory()
    let project = ProjectRecord(rootPath: "/tmp/storefront", name: "storefront")
    try await database.write { database in
      try ProjectRecord.insert { project }.execute(database)
    }

    try await recordingCommandRun("status", in: database) { recorder in
      await recorder.attach(project: project.id)
    }

    let command = try #require(try await commandRun(in: database))
    #expect(command.command == "status")
    #expect(command.outcome == .complete)
    #expect(command.completedAt != nil)
    #expect(command.projectID == project.id)
  }

  @Test
  func `Records nothing for an operation run outside a recorded command`() async throws {
    let database = try TestDatabase.inMemory()

    _ = try await #run($succeeds(1))

    #expect(try await recorded(in: database).isEmpty)
    #expect(try await commandRun(in: database) == nil)
  }

  // MARK: - Reading back

  private func recorded(in database: any DatabaseWriter) async throws -> [OperationRunRecord] {
    try await database.read { database in
      try OperationRunRecord.all.order { $0.startedAt }.fetchAll(database)
    }
  }

  private func commandRun(in database: any DatabaseWriter) async throws -> CommandRunRecord? {
    try await database.read { database in try CommandRunRecord.all.fetchOne(database) }
  }
}

// MARK: - Operations

private struct RecordedFailure: Error {}

private final class AttemptCounter: Sendable {
  private let state = Mutex(0)

  @discardableResult
  func record() -> Int {
    state.withLock { count in
      count += 1
      return count
    }
  }
}

@OperationRequest
private func succeeds(_ value: Int) async throws -> Int {
  value
}

@OperationRequest
private func alsoSucceeds() async throws -> Int {
  0
}

@OperationRequest
private func callsAnother() async throws -> Int {
  try await #run($succeeds(1))
}

@OperationRequest
private func fails() async throws -> Int {
  throw RecordedFailure()
}

@OperationRequest
private func readyOnAttempt(
  _ counter: AttemptCounter,
  _ attempt: Int
) async throws -> PollAttempt<Int> {
  counter.record() < attempt ? .notYet : .ready(attempt)
}
