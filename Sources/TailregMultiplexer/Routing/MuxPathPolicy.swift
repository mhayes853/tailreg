import Foundation
import TailregCore

public enum MuxPathPolicyError: Error, Equatable, Sendable {
  case invalidExternalPathPrefix
}

public struct MuxPathPolicy: Equatable, Sendable {
  public let externalPathPrefix: String

  public init() {
    self.externalPathPrefix = ""
  }

  public init(externalPathPrefix: String) throws {
    let prefix = externalPathPrefix == "/" ? "" : externalPathPrefix
    guard prefix.isEmpty || Self.isValidPrefix(prefix) else {
      throw MuxPathPolicyError.invalidExternalPathPrefix
    }
    self.externalPathPrefix = prefix
  }

  public func publicPath(route: String, remainder: String = "/") -> String {
    join(externalPathPrefix, "/\(route)", normalizedRemainder(remainder))
  }

  public func forwardedPrefix(route: String) -> String {
    join(externalPathPrefix, "/\(route)")
  }

  public func upstreamPath(
    route: String,
    remainder: String,
    mode: MuxRoutePathMode
  ) -> String {
    switch mode {
    case .stripRoutePrefix:
      return normalizedRemainder(remainder)
    case .preserveRoutePrefix:
      return join("/\(route)", normalizedRemainder(remainder))
    }
  }

  private static func isValidPrefix(_ prefix: String) -> Bool {
    prefix.first == "/"
      && prefix.last != "/"
      && !prefix.contains("?")
      && !prefix.contains("#")
      && !prefix.contains("//")
  }

  private func normalizedRemainder(_ remainder: String) -> String {
    guard !remainder.isEmpty else { return "/" }
    return remainder.first == "/" ? remainder : "/\(remainder)"
  }

  private func join(_ components: String...) -> String {
    let preservesTrailingSlash = components.last?.hasSuffix("/") == true
    let joined =
      components
      .filter { !$0.isEmpty && $0 != "/" }
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      .filter { !$0.isEmpty }
      .joined(separator: "/")
    let path = "/\(joined)"
    if preservesTrailingSlash, path != "/" { return path + "/" }
    return path
  }
}
