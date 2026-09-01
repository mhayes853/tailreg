import Hummingbird
import TailregCore

public enum CapturedHeaderPolicy: Equatable, Sendable {
  case redactSensitiveValues
  case retainAllValues
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
