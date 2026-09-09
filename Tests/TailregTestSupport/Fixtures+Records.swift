import Foundation
import SQLiteData
import TailregCore
import UUIDV7

extension PortNumber {
  /// A port written as a literal that is valid by inspection.
  ///
  /// `PortNumber` is deliberately not `ExpressibleByIntegerLiteral`, which is right for
  /// production code reading numbers it did not choose, and only noise in a test naming a fixed
  /// port it did.
  public static func fixed(_ rawValue: UInt16) -> PortNumber {
    PortNumber(rawValue: rawValue)!
  }
}

extension TailscaleBindingRecord {
  /// A binding record with everything a test does not care about already filled in.
  public static func fixture(
    id: UUIDV7 = UUIDV7(),
    hostname: String = "node.example.ts.net",
    localPort: PortNumber = .fixed(3000),
    tailnetPort: PortNumber = .fixed(443),
    proto: TailscaleServeProtocol = .https,
    mountPath: String = "/",
    status: TailscaleBindingStatus = .active,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    endedAt: Date? = nil,
    endReason: TailscaleBindingEndReason? = nil
  ) -> TailscaleBindingRecord {
    TailscaleBindingRecord(
      id: id,
      hostname: hostname,
      localPort: localPort,
      tailnetPort: tailnetPort,
      proto: proto,
      mountPath: mountPath,
      status: status,
      createdAt: createdAt,
      endedAt: endedAt,
      endReason: endReason
    )
  }
}
