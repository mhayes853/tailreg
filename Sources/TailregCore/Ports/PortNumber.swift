import Foundation

/// A TCP or UDP port number.
///
/// Values are constrained to `1...65535`. Port `0` is rejected because it is the
/// "assign me one" sentinel for `bind`, never an address that anything can be reached on.
/// Admitting it would leave every consumer re-checking for it.
///
/// Deliberately not `ExpressibleByIntegerLiteral`: the literal initializer cannot fail, and
/// it shadows `init?(_:)` for literal arguments, which would make `PortNumber(0)` trap rather
/// than return `nil` — the one value this type exists to reject.
public struct PortNumber: RawRepresentable, Sendable, Hashable, Comparable, Codable,
  CustomStringConvertible
{
  public let rawValue: UInt16

  public init?(rawValue: UInt16) {
    guard rawValue != 0 else { return nil }
    self.rawValue = rawValue
  }

  public init?(_ value: some BinaryInteger) {
    guard let narrowed = UInt16(exactly: value) else { return nil }
    self.init(rawValue: narrowed)
  }

  /// Reads a port held in network byte order, as `sockaddr_in.sin_port` and libproc's
  /// `insi_lport` both are.
  public init?(bigEndian value: UInt16) {
    self.init(rawValue: UInt16(bigEndian: value))
  }

  /// Reads the port half of a `/proc/net/tcp` `local_address` field.
  public init?(hex: some StringProtocol) {
    guard let value = UInt16(hex, radix: 16) else { return nil }
    self.init(rawValue: value)
  }

  /// The port in network byte order, ready for `sockaddr_in.sin_port`.
  public var bigEndian: UInt16 { rawValue.bigEndian }

  public var description: String { String(rawValue) }

  /// The port as a plain integer, for the many system APIs typed that way.
  public var intValue: Int { Int(rawValue) }

  /// Ports below 1024 need root to bind, so a dev server on one is nearly always a mistake.
  public var isPrivileged: Bool { rawValue < 1024 }

  /// The IANA dynamic range. The kernel hands these out for `bind` on port 0, so a port
  /// recorded from this range can be taken by another process across a restart.
  public var isEphemeral: Bool { rawValue >= 49152 }

  public static func < (lhs: PortNumber, rhs: PortNumber) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

// MARK: - Codable

extension PortNumber {
  /// Encoded as a bare number rather than the keyed container the compiler would synthesize,
  /// so that decoding runs through `init?(rawValue:)` and rejects a stored `0`.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(UInt16.self)
    guard let port = PortNumber(rawValue: rawValue) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "\(rawValue) is not a valid port number"
      )
    }
    self = port
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
