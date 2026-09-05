import Foundation
import TailregCore

extension FileLock {
  /// The lock every change to a MUX, a route, a binding, or an application process is taken
  /// under.
  ///
  /// It is derived from the database path so that two invocations sharing a database serialize
  /// against each other, and two test runs with their own state directories do not. Named here
  /// because three commands take it: spelling the suffix out at each of them is how one of them
  /// ends up locking a different file from the rest.
  static func runtime(forDatabaseAt databasePath: String) -> FileLock {
    FileLock(path: databasePath + ".runtime.lock")
  }
}
