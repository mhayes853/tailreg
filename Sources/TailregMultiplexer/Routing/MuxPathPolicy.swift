import Foundation
import TailregCore

public struct MuxPathPolicy: Equatable, Sendable {
  public init() {}

  public func publicPath(route: String, remainder: String = "/") -> String {
    join("/\(route)", normalizedRemainder(remainder))
  }

  public func forwardedPrefix(route: String) -> String {
    join("/\(route)")
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
