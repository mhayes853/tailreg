import Foundation

/// A duration configured through the environment as a positive number of milliseconds.
///
/// Every timeout Tailreg reads from the environment has the same shape and the same failure
/// mode, so they share one reader rather than each carrying its own copy of the validation.
public struct MillisecondsSetting: Hashable, Sendable {
  public let environmentKey: String
  public let defaultValue: Duration

  public init(environmentKey: String, defaultValue: Duration) {
    self.environmentKey = environmentKey
    self.defaultValue = defaultValue
  }

  /// The configured duration, or the default when the variable is unset.
  public func resolve(from environment: [String: String]) throws -> Duration {
    guard let configured = environment[environmentKey] else { return defaultValue }
    guard let milliseconds = Int64(configured), milliseconds > 0 else {
      throw MillisecondsSettingError.invalid(key: environmentKey, value: configured)
    }
    return .milliseconds(milliseconds)
  }
}

public enum MillisecondsSettingError: Error, Equatable, CustomStringConvertible {
  case invalid(key: String, value: String)

  public var description: String {
    switch self {
    case .invalid(let key, let value):
      "\(key) must be a positive millisecond value, not '\(value)'"
    }
  }
}

extension MillisecondsSetting {
  /// How long a process is given to stop after SIGTERM before it is killed.
  public static let terminationGrace = MillisecondsSetting(
    environmentKey: "TAILREG_STOP_TIMEOUT_MS",
    defaultValue: .seconds(5)
  )
}
