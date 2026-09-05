import Foundation
import SQLiteData
import UUIDV7

@Table("muxInstances")
public struct MuxInstanceRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var createdAt: Date
  public var endedAt: Date?

  public init(
    id: UUIDV7 = UUIDV7(),
    createdAt: Date = Date(),
    endedAt: Date? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.endedAt = endedAt
  }
}

public enum MuxRoutePathMode: String, Codable, Equatable, Sendable {
  case stripRoutePrefix = "strip-route-prefix"
  case preserveRoutePrefix = "preserve-route-prefix"
}

extension MuxRoutePathMode: QueryBindable, QueryDecodable {}

@Table("muxRoutes")
public struct MuxRouteRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var muxID: UUIDV7
  public var name: String
  public var route: String
  public var upstreamURL: String
  public var pathMode: MuxRoutePathMode
  public var createdAt: Date
  public var endedAt: Date?

  public init(
    id: UUIDV7 = UUIDV7(),
    muxID: UUIDV7,
    name: String,
    route: String,
    upstreamURL: String,
    pathMode: MuxRoutePathMode = .stripRoutePrefix,
    createdAt: Date,
    endedAt: Date? = nil
  ) {
    self.id = id
    self.muxID = muxID
    self.name = name
    self.route = route
    self.upstreamURL = upstreamURL
    self.pathMode = pathMode
    self.createdAt = createdAt
    self.endedAt = endedAt
  }

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
