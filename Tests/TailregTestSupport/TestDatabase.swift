import SQLiteData
import TailregCore

/// Migrated databases for tests.
///
/// A test that needs one connection wants the in-memory database: it costs no filesystem and
/// cannot leak state between runs. A test about what a *second* connection sees needs a file,
/// because an in-memory database is private to the connection that opened it.
public enum TestDatabase {
  public static func inMemory() throws -> any DatabaseWriter {
    try openTailregDatabase(path: ":memory:", kind: .queue)
  }

  public static func onDisk(
    in directory: TempDirectory,
    named name: String = "tailreg.sqlite",
    kind: TailregDatabaseKind = .queue
  ) throws -> any DatabaseWriter {
    try openTailregDatabase(path: directory.path(name), kind: kind)
  }
}
