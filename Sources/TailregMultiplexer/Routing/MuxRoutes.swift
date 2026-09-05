import Foundation
import SQLiteData
import TailregCore
import UUIDV7

public struct MultiplexerBinding: Equatable, Sendable {
  public let id: UUIDV7
  public let muxID: UUIDV7
  public let name: String
  public let route: MuxRouteName
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
  case routeAlreadyExists(MuxRouteName)
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
    try MuxRouteRecord.live(muxID: muxID).fetchAll(database)
  }

  static func live(
    muxID: UUIDV7,
    route: MuxRouteName,
    in database: Database
  ) throws -> MuxRouteRecord? {
    try MuxRouteRecord.live(muxID: muxID, route: route).fetchOne(database)
  }

  static func register(
    muxID: UUIDV7,
    name: String,
    requestedRoute: MuxRouteName?,
    upstream: URL,
    pathMode: MuxRoutePathMode,
    in database: Database
  ) throws -> MuxRouteRecord {
    guard let normalizedName = normalize(name: name) else {
      throw MuxRouteError.invalidName
    }
    try validate(upstream: upstream)

    let occupiedRoutes = Set(try live(muxID: muxID, in: database).map(\.route))
    let route: MuxRouteName
    if let requestedRoute {
      guard !occupiedRoutes.contains(requestedRoute) else {
        throw MuxRouteError.routeAlreadyExists(requestedRoute)
      }
      route = requestedRoute
    } else {
      route = try generatedRoute(for: normalizedName, avoiding: occupiedRoutes)
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
    route: MuxRouteName,
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
    route: MuxRouteName,
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

  /// The first `<name>-<suffix>` this MUX is not already serving.
  ///
  /// The suffix is what makes two applications of the same name addressable, so the name is
  /// normalized first and the pair is then built through the route initializer rather than
  /// assumed to be well formed.
  private static func generatedRoute(
    for normalizedName: String,
    avoiding occupiedRoutes: Set<MuxRouteName>
  ) throws -> MuxRouteName {
    var suffix = 0
    while true {
      guard let candidate = MuxRouteName(rawValue: "\(normalizedName)-\(suffix)") else {
        throw MuxRouteError.invalidName
      }
      if !occupiedRoutes.contains(candidate) { return candidate }
      suffix += 1
    }
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
}
