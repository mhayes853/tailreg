import Foundation

public struct MultiplexerBinding: Equatable, Sendable {
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

  public init() {}

  @discardableResult
  public func register(name: String, upstream: URL) throws -> MultiplexerBinding {
    guard let normalizedName = Self.normalize(name: name) else {
      throw BindingRegistryError.invalidName
    }
    guard upstream.scheme == "http" || upstream.scheme == "https", upstream.host != nil else {
      throw BindingRegistryError.invalidUpstream
    }

    var suffix = 0
    var route = "\(normalizedName)-\(suffix)"
    while bindingsByRoute[route] != nil {
      suffix += 1
      route = "\(normalizedName)-\(suffix)"
    }

    let binding = MultiplexerBinding(
      name: name,
      route: route,
      upstream: upstream,
      token: UUID().uuidString.lowercased()
    )
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
  public func unregister(route: String) -> MultiplexerBinding? {
    bindingsByRoute.removeValue(forKey: route)
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
