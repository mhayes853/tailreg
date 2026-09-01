import Foundation
import SQLiteData
import TailregCore
import UUIDV7

public struct MultiplexerBinding: Equatable, Sendable {
  public let id: UUIDV7
  public let muxID: UUIDV7
  public let name: String
  public let route: String
  public let upstream: URL
  public let pathMode: MuxRoutePathMode
  private let pathPolicy: MuxPathPolicy

  public var publicPath: String { pathPolicy.publicPath(route: route) }

  init(record: MuxRouteRecord, pathPolicy: MuxPathPolicy) throws {
    guard let upstream = URL(string: record.upstreamURL) else {
      throw MuxRouteError.invalidPersistedUpstream(record.upstreamURL)
    }
    self.id = record.id
    self.muxID = record.muxID
    self.name = record.name
    self.route = record.route
    self.upstream = upstream
    self.pathMode = record.pathMode
    self.pathPolicy = pathPolicy
  }
}

public enum MuxRouteError: Error, Equatable, Sendable {
  case invalidName
  case invalidRoute
  case routeAlreadyExists(String)
  case invalidUpstream
  case invalidPersistedUpstream(String)
  case routeNotFound
}

enum MuxRouteQueries {
  static func prepare(muxID: UUIDV7, in database: Database) throws {
    if try MuxInstanceRecord.find(muxID).fetchOne(database) == nil {
      let instance = MuxInstanceRecord(id: muxID)
      try MuxInstanceRecord.insert { instance }.execute(database)
    }
  }

  static func live(muxID: UUIDV7, in database: Database) throws -> [MuxRouteRecord] {
    try MuxRouteRecord
      .where { $0.muxID.eq(muxID) && $0.endedAt.is(nil) }
      .order { ($0.route, $0.createdAt) }
      .fetchAll(database)
  }

  static func live(
    muxID: UUIDV7,
    route: String,
    in database: Database
  ) throws -> MuxRouteRecord? {
    try MuxRouteRecord
      .where { $0.muxID.eq(muxID) && $0.route.eq(route) && $0.endedAt.is(nil) }
      .fetchOne(database)
  }

  static func register(
    muxID: UUIDV7,
    name: String,
    requestedRoute: String?,
    upstream: URL,
    pathMode: MuxRoutePathMode,
    in database: Database
  ) throws -> MuxRouteRecord {
    guard let normalizedName = normalize(name: name) else {
      throw MuxRouteError.invalidName
    }
    try validate(upstream: upstream)

    let occupiedRoutes = Set(try live(muxID: muxID, in: database).map(\.route))
    let route: String
    if let requestedRoute {
      guard let normalizedRoute = normalize(route: requestedRoute) else {
        throw MuxRouteError.invalidRoute
      }
      guard !occupiedRoutes.contains(normalizedRoute) else {
        throw MuxRouteError.routeAlreadyExists(normalizedRoute)
      }
      route = normalizedRoute
    } else {
      var suffix = 0
      var candidate = "\(normalizedName)-\(suffix)"
      while occupiedRoutes.contains(candidate) {
        suffix += 1
        candidate = "\(normalizedName)-\(suffix)"
      }
      route = candidate
    }

    let record = MuxRouteRecord(
      muxID: muxID,
      name: name,
      route: route,
      upstreamURL: upstream.absoluteString,
      pathMode: pathMode,
      createdAt: Date()
    )
    try MuxRouteRecord.insert { record }.execute(database)
    return record
  }

  static func update(
    muxID: UUIDV7,
    route: String,
    upstream: URL,
    pathMode: MuxRoutePathMode?,
    in database: Database
  ) throws -> MuxRouteRecord {
    try validate(upstream: upstream)
    guard var record = try live(muxID: muxID, route: route, in: database) else {
      throw MuxRouteError.routeNotFound
    }
    record.upstreamURL = upstream.absoluteString
    if let pathMode { record.pathMode = pathMode }
    try MuxRouteRecord
      .where { $0.id.eq(record.id) && $0.endedAt.is(nil) }
      .update {
        $0.upstreamURL = #bind(record.upstreamURL)
        $0.pathMode = #bind(record.pathMode)
      }
      .execute(database)
    return record
  }

  static func unregister(
    muxID: UUIDV7,
    route: String,
    in database: Database
  ) throws -> MuxRouteRecord? {
    guard let record = try live(muxID: muxID, route: route, in: database) else {
      return nil
    }
    try MuxRouteRecord
      .where { $0.id.eq(record.id) && $0.endedAt.is(nil) }
      .update { $0.endedAt = #bind(Date()) }
      .execute(database)
    return record
  }

  private static func validate(upstream: URL) throws {
    guard upstream.scheme == "http" || upstream.scheme == "https", upstream.host != nil else {
      throw MuxRouteError.invalidUpstream
    }
  }

  private static func normalize(name: String) -> String? {
    let normalized = name.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    guard !normalized.isEmpty else { return nil }
    return String(normalized.prefix(48))
  }

  private static func normalize(route: String) -> String? {
    guard route == route.lowercased(), route.count <= 64 else { return nil }
    let characters = Array(route)
    guard let first = characters.first, let last = characters.last,
      first.isLetter || first.isNumber,
      last.isLetter || last.isNumber,
      characters.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" })
    else {
      return nil
    }
    return route
  }
}
