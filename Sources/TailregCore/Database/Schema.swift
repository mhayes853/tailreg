import Foundation
import SQLiteData
import UUIDV7

extension TailscaleServeProtocol: QueryBindable, QueryDecodable {}
extension TailscaleBindingStatus: QueryBindable, QueryDecodable {}
extension TailscaleBindingEndReason: QueryBindable, QueryDecodable {}

@Table("bindings")
public struct TailscaleBindingRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var hostname: String
  public var localPort: Int
  public var tailnetPort: Int
  public var proto: TailscaleServeProtocol
  public var mountPath: String
  public var status: TailscaleBindingStatus
  public var createdAt: Date
  public var endedAt: Date?
  public var endReason: TailscaleBindingEndReason?

  public init(
    id: UUIDV7 = UUIDV7(),
    hostname: String,
    localPort: Int,
    tailnetPort: Int,
    proto: TailscaleServeProtocol,
    mountPath: String,
    status: TailscaleBindingStatus = .pending,
    createdAt: Date,
    endedAt: Date? = nil,
    endReason: TailscaleBindingEndReason? = nil
  ) {
    self.id = id
    self.hostname = hostname
    self.localPort = localPort
    self.tailnetPort = tailnetPort
    self.proto = proto
    self.mountPath = mountPath
    self.status = status
    self.createdAt = createdAt
    self.endedAt = endedAt
    self.endReason = endReason
  }

  public var isLive: Bool { endedAt == nil }

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
        "hostname"    TEXT    NOT NULL,
        "localPort"   INTEGER NOT NULL,
        "tailnetPort" INTEGER NOT NULL,
        "proto"       TEXT    NOT NULL,
        "mountPath"   TEXT    NOT NULL,
        "status"      TEXT    NOT NULL,
        "createdAt"   TEXT    NOT NULL,
        "endedAt"     TEXT,
        "endReason"   TEXT,

        CHECK ("tailnetPort" BETWEEN 1 AND 65535),
        CHECK ("localPort"   BETWEEN 1 AND 65535),
        CHECK ("proto"  IN ('https', 'http', 'tcp', 'tls-terminated-tcp')),
        CHECK ("status" IN ('pending', 'active', 'ended')),
        CHECK ("mountPath" LIKE '/%'),
        CHECK ("endReason" IS NULL OR "endReason" IN ('unbound', 'expired', 'failed')),
        CHECK (("endedAt" IS NULL) = ("endReason" IS NULL)),
        CHECK (("status" = 'ended') = ("endedAt" IS NOT NULL))
      ) STRICT
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE UNIQUE INDEX "bindings_live_target"
        ON "bindings" ("tailnetPort", "proto", "mountPath")
        WHERE "endedAt" IS NULL
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE INDEX "bindings_created_at" ON "bindings" ("createdAt" DESC)
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
