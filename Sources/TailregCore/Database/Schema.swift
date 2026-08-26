import Foundation
import SQLiteData

extension TailscaleServeProtocol: QueryBindable, QueryDecodable {}

@Table("bindings")
struct TailscaleBindingRecord: Hashable, Sendable {
  let id: UUIDV7
  var localPort: Int
  var tailnetPort: Int
  var proto: TailscaleServeProtocol
  var mountPath: String
  var createdAt: Date

  init(
    id: UUIDV7 = UUIDV7(),
    localPort: Int,
    tailnetPort: Int,
    proto: TailscaleServeProtocol,
    mountPath: String,
    createdAt: Date
  ) {
    self.id = id
    self.localPort = localPort
    self.tailnetPort = tailnetPort
    self.proto = proto
    self.mountPath = mountPath
    self.createdAt = createdAt
  }

  func claims(_ binding: TailscaleBinding) -> Bool {
    binding.tailnetPort == tailnetPort
      && binding.proto == proto
      && binding.mountPath == mountPath
      && binding.localPort == localPort
  }
}

public func tailregDatabaseConfiguration() -> Configuration {
  var configuration = Configuration()
  configuration.busyMode = .timeout(5)
  configuration.prepareDatabase { db in
    try db.execute(sql: "PRAGMA journal_mode = WAL")
    try db.execute(sql: "PRAGMA foreign_keys = ON")
  }
  return configuration
}

public func tailregDatabaseMigrator() -> DatabaseMigrator {
  var migrator = DatabaseMigrator()

  migrator.registerMigration("v1: create bindings") { db in
    try #sql(
      """
      CREATE TABLE "bindings" (
        "id"          TEXT    NOT NULL PRIMARY KEY,
        "localPort"   INTEGER NOT NULL,
        "tailnetPort" INTEGER NOT NULL,
        "proto"       TEXT    NOT NULL,
        "mountPath"   TEXT    NOT NULL,
        "createdAt"   TEXT    NOT NULL,

        UNIQUE ("tailnetPort", "proto", "mountPath"),

        CHECK ("tailnetPort" BETWEEN 1 AND 65535),
        CHECK ("localPort"   BETWEEN 1 AND 65535),
        CHECK ("proto" IN ('https', 'http', 'tcp', 'tls-terminated-tcp')),
        CHECK ("mountPath" LIKE '/%')
      ) STRICT
      """
    )
    .execute(db)
  }

  return migrator
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
