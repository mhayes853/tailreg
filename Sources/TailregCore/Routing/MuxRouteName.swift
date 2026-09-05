import SQLiteData

/// A stable route: what may appear as the first public path segment.
///
/// Mirrors the CHECK constraint on `muxRoutes.route`, so the CLI, the MUX and the schema cannot
/// disagree. A predicate over `Character` cannot: `isLowercase` and `isNumber` accept `café` and
/// `٣`, which SQLite's `GLOB '[a-z0-9]*'` then rejects at registration time, long after the
/// route was validated.
public struct MuxRouteName: RawRepresentable, Hashable, Sendable, Codable,
  CustomStringConvertible
{
  public let rawValue: String

  /// 1–64 ASCII characters from `a-z`, `0-9` and `-`; the first and last are alphanumeric.
  public init?(rawValue: String) {
    let bytes = rawValue.utf8
    guard (1...64).contains(bytes.count),
      let first = bytes.first,
      let last = bytes.last,
      Self.isAlphanumeric(first),
      Self.isAlphanumeric(last),
      bytes.allSatisfy({ Self.isAlphanumeric($0) || $0 == UInt8(ascii: "-") })
    else { return nil }
    self.rawValue = rawValue
  }

  public var description: String { rawValue }

  private static func isAlphanumeric(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
  }
}

// MARK: - Persistence

/// Stored as the `String` it wraps, so the column stays an ordinary TEXT and the CHECK the
/// schema already carries stays the one place the shape is written down.
extension MuxRouteName: QueryBindable, QueryDecodable {}

// MARK: - Codable

extension MuxRouteName {
  /// Encoded as a bare string rather than the keyed container the compiler would synthesize, so
  /// that decoding runs through `init?(rawValue:)` and a registration naming an impossible route
  /// fails to decode rather than reaching the database.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    guard let route = MuxRouteName(rawValue: rawValue) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "'\(rawValue)' is not a valid route name"
      )
    }
    self = route
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
