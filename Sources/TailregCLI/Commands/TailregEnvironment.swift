import Foundation
import TailregCore

extension [String: String] {
  /// The database every command works against: `TAILREG_DATABASE_PATH`, else the default.
  var tailregDatabasePath: String {
    self["TAILREG_DATABASE_PATH"] ?? defaultTailregDatabasePath()
  }
}
