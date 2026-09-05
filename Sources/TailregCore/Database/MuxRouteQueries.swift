import Foundation
import SQLiteData
import UUIDV7

extension MuxRouteRecord {
  /// The routes a MUX is currently serving.
  public static func live(muxID: UUIDV7) -> SelectOf<MuxRouteRecord> {
    MuxRouteRecord
      .where { $0.muxID.eq(muxID) && $0.endedAt.is(nil) }
      .order { ($0.route, $0.createdAt) }
  }

  public static func live(muxID: UUIDV7, route: String) -> Where<MuxRouteRecord> {
    MuxRouteRecord.where { $0.muxID.eq(muxID) && $0.route.eq(route) && $0.endedAt.is(nil) }
  }
}
