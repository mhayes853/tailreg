import Hummingbird
import TailregCore
import UUIDV7

public enum CapturedHeaderPolicy: Equatable, Sendable {
  case redactSensitiveValues
  case retainAllValues
}

public enum UnmatchedPathPolicy: Equatable, Sendable {
  case reject
  case lastSelectedRouteCompatibility
}

extension CapturedHeaderPolicy {
  private static let sensitiveNames: Set<String> = [
    "authorization", "cookie", "proxy-authorization", "set-cookie", "x-api-key"
  ]

  func capture(name: String, value: String) -> CapturedHTTPHeader {
    let normalizedName = name.lowercased()
    let shouldRedact =
      self == .redactSensitiveValues && Self.sensitiveNames.contains(normalizedName)
    return CapturedHTTPHeader(
      name: normalizedName,
      value: shouldRedact ? "[REDACTED]" : value
    )
  }
}

public struct MultiplexerStatus: ResponseCodable, Equatable, Sendable {
  public let status: String

  public init(status: String) {
    self.status = status
  }
}

public struct MultiplexerErrorResponse: ResponseCodable, Equatable, Sendable {
  public let error: String
  public let message: String?

  public init(error: String, message: String? = nil) {
    self.error = error
    self.message = message
  }
}

public struct MuxRouteRegistrationRequest: Codable, Equatable, Sendable {
  public let name: String
  public let upstreamURL: String
  public let pathMode: MuxRoutePathMode

  public init(
    name: String,
    upstreamURL: String,
    pathMode: MuxRoutePathMode = .stripRoutePrefix
  ) {
    self.name = name
    self.upstreamURL = upstreamURL
    self.pathMode = pathMode
  }
}

public struct MuxRouteUpdateRequest: Codable, Equatable, Sendable {
  public let upstreamURL: String
  public let pathMode: MuxRoutePathMode?

  public init(upstreamURL: String, pathMode: MuxRoutePathMode? = nil) {
    self.upstreamURL = upstreamURL
    self.pathMode = pathMode
  }
}

public struct MuxRouteResponse: ResponseCodable, Equatable, Sendable {
  public let id: UUIDV7
  public let muxID: UUIDV7
  public let name: String
  public let route: String
  public let upstreamURL: String
  public let pathMode: MuxRoutePathMode
  public let publicPath: String

  public init(_ binding: MultiplexerBinding) {
    self.id = binding.id
    self.muxID = binding.muxID
    self.name = binding.name
    self.route = binding.route
    self.upstreamURL = binding.upstream.absoluteString
    self.pathMode = binding.pathMode
    self.publicPath = binding.publicPath
  }
}
