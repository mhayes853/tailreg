import Foundation
import SQLiteData

public func tailregDatabaseConfiguration() -> Configuration {
  var configuration = Configuration()
  configuration.busyMode = .timeout(5)
  configuration.prepareDatabase { db in
    try db.execute(sql: "PRAGMA journal_mode = WAL")
    try db.execute(sql: "PRAGMA foreign_keys = ON")
  }
  return configuration
}

public enum TailregDatabaseKind: Sendable {
  case pool
  case queue
}

public func defaultTailregDatabasePath(
  environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
  let home = environment["HOME"] ?? NSHomeDirectory()
  #if os(macOS)
    return "\(home)/Library/Application Support/tailreg/tailreg.sqlite"
  #else
    let stateHome =
      environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.local/state"
    return "\(stateHome)/tailreg/tailreg.sqlite"
  #endif
}

public func openTailregDatabase(
  path: String = defaultTailregDatabasePath(),
  kind: TailregDatabaseKind = .pool
) throws -> any DatabaseWriter {
  do {
    try createTailregDatabaseDirectory(for: path)
    let writer = try makeTailregDatabaseWriter(kind: kind, path: path)
    try tailregDatabaseMigrator().migrate(writer)
    return writer
  } catch {
    throw TailscaleError.databaseUnavailable(path: path, detail: String(describing: error))
  }
}

private func makeTailregDatabaseWriter(
  kind: TailregDatabaseKind,
  path: String
) throws -> any DatabaseWriter {
  let configuration = tailregDatabaseConfiguration()
  switch kind {
  case .pool: return try DatabasePool(path: path, configuration: configuration)
  case .queue: return try DatabaseQueue(path: path, configuration: configuration)
  }
}

private func createTailregDatabaseDirectory(for path: String) throws {
  let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
  guard !FileManager.default.fileExists(atPath: directory.path) else { return }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}
