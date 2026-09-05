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
