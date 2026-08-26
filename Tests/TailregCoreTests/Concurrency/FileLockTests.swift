import Foundation
import Testing

@testable import TailregCore

@Suite
struct `FileLock tests` {
  private func makeLock(_ temp: TempDirectory, timeout: Duration = .milliseconds(200)) -> FileLock {
    var lock = FileLock(path: temp.path("tailreg.sqlite.lock"))
    lock.timeout = timeout
    return lock
  }

  @Test
  func `An Exclusive Holder Shuts Out A Second Exclusive Waiter`() async throws {
    let temp = try TempDirectory()
    let lock = makeLock(temp)
    let contender = makeLock(temp)

    try await lock.withLock(.exclusive) {
      await #expect(throws: TailscaleError.self) {
        try await contender.withLock(.exclusive) {}
      }
    }
  }

  @Test
  func `Two Shared Readers Hold The Lock At The Same Time`() async throws {
    let temp = try TempDirectory()
    let lock = makeLock(temp)
    let other = makeLock(temp)

    try await lock.withLock(.shared) {
      let reachedInner = try await other.withLock(.shared) { true }
      #expect(reachedInner)
    }
  }

  @Test
  func `A Shared Holder Shuts Out An Exclusive Waiter`() async throws {
    let temp = try TempDirectory()
    let lock = makeLock(temp)
    let writer = makeLock(temp)

    try await lock.withLock(.shared) {
      await #expect(throws: TailscaleError.self) {
        try await writer.withLock(.exclusive) {}
      }
    }
  }

  @Test
  func `Releases The Lock Once The Critical Section Ends`() async throws {
    let temp = try TempDirectory()
    let lock = makeLock(temp)
    let next = makeLock(temp)

    try await lock.withLock(.exclusive) {}
    let acquired = try await next.withLock(.exclusive) { true }

    #expect(acquired)
  }

  @Test
  func `Releases The Lock When The Critical Section Throws`() async throws {
    struct Boom: Error {}
    let temp = try TempDirectory()
    let lock = makeLock(temp)
    let next = makeLock(temp)

    await #expect(throws: Boom.self) {
      try await lock.withLock(.exclusive) { throw Boom() }
    }
    let acquired = try await next.withLock(.exclusive) { true }

    #expect(acquired)
  }
}
