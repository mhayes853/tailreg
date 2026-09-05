import Foundation
import SQLiteData
import TailregCore
import Testing

@testable import TailregCLI

/// The ancestor walk used to rely on a parent path repeating itself to know it had run out of
/// directories. Darwin keeps walking past the root by appending "..", so the parent never repeats
/// and the walk ran forever, growing its path until the process thrashed. The time limit is the
/// assertion that matters here.
@Suite(.timeLimit(.minutes(1)))
struct `Project resolver tests` {
  @Test
  func `A directory with no project marker above it resolves to itself`() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("tailreg-resolver-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try openTailregDatabase(
      path: root.appendingPathComponent("tailreg.sqlite").path
    )

    let inspected = try await ResolvedProject.inspect(
      database: database,
      explicitPath: nil,
      currentDirectory: root
    )

    #expect(inspected.record == nil)
    #expect(inspected.root.path == root.standardizedFileURL.resolvingSymlinksInPath().path)
  }
}
