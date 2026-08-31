import Foundation
import SQLiteData
import TailregCore
import UUIDV7

public struct MultiplexerBinding: Equatable, Sendable {
  public let id: UUIDV7
  public let name: String
  public let route: String
  public let upstream: URL
  let token: String

  public var publicPath: String { "/\(route)/" }
}

public enum BindingRegistryError: Error, Equatable {
  case invalidName
  case invalidUpstream
}

public actor BindingRegistry {
  private var bindingsByRoute: [String: MultiplexerBinding] = [:]
  private let database: (any DatabaseWriter)?

  public init(database: (any DatabaseWriter)? = nil) {
    self.database = database
  }

  @discardableResult
  public func register(name: String, upstream: URL) async throws -> MultiplexerBinding {
    guard let normalizedName = Self.normalize(name: name) else {
      throw BindingRegistryError.invalidName
    }
    guard upstream.scheme == "http" || upstream.scheme == "https", upstream.host != nil else {
      throw BindingRegistryError.invalidUpstream
    }

    var occupiedRoutes = Set(bindingsByRoute.keys)
    if let database {
      let persistedRoutes = try await database.read { db in
        try MuxRouteRecord
          .where { $0.endedAt.is(nil) }
          .select { $0.route }
          .fetchAll(db)
      }
      occupiedRoutes.formUnion(persistedRoutes)
    }

    var suffix = 0
    var route = "\(normalizedName)-\(suffix)"
    while occupiedRoutes.contains(route) {
      suffix += 1
      route = "\(normalizedName)-\(suffix)"
    }

    let bindingID = UUIDV7()
    let createdAt = Date()
    let binding = MultiplexerBinding(
      id: bindingID,
      name: name,
      route: route,
      upstream: upstream,
      token: UUID().uuidString.lowercased()
    )
    if let database {
      let record = MuxRouteRecord(
        id: bindingID,
        name: name,
        route: route,
        upstreamURL: upstream.absoluteString,
        createdAt: createdAt
      )
      try await database.write { db in
        try MuxRouteRecord.insert { record }.execute(db)
      }
    }
    bindingsByRoute[route] = binding
    return binding
  }

  public func binding(route: String) -> MultiplexerBinding? {
    bindingsByRoute[route]
  }

  public func binding(token: String) -> MultiplexerBinding? {
    bindingsByRoute.values.first { $0.token == token }
  }

  public func bindings() -> [MultiplexerBinding] {
    bindingsByRoute.values.sorted { $0.route < $1.route }
  }

  public func issueToken(for route: String) -> String? {
    bindingsByRoute[route]?.token
  }

  @discardableResult
  public func unregister(route: String) async throws -> MultiplexerBinding? {
    guard let binding = bindingsByRoute[route] else { return nil }
    if let database {
      let endedAt = Date()
      try await database.write { db in
        try MuxRouteRecord
          .where { $0.id.eq(binding.id) && $0.endedAt.is(nil) }
          .update { $0.endedAt = #bind(endedAt) }
          .execute(db)
      }
    }
    return bindingsByRoute.removeValue(forKey: route)
  }

  public func count() -> Int {
    bindingsByRoute.count
  }

  static func normalize(name: String) -> String? {
    let normalized = name.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    guard !normalized.isEmpty else { return nil }
    return String(normalized.prefix(48))
  }
}
