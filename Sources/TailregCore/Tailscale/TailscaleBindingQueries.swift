import Foundation
import SQLiteData

extension TailscaleBindingRecord {
  /// The bindings currently serving a local port, oldest first.
  public static func live(localPort: Int) -> SelectOf<TailscaleBindingRecord> {
    TailscaleBindingRecord
      .where { $0.localPort.eq(localPort) && $0.endedAt.is(nil) }
      .order { $0.createdAt }
  }
}
