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

  /// Inserts a binding and reports its identifier, for the tests whose subject is what hangs off
  /// a binding rather than the binding itself.
  @discardableResult
  public static func insertFixture(
    into database: any DatabaseWriter,
    tailnetPort: PortNumber = .fixed(443),
    endedAt: Date? = nil
  ) async throws -> UUIDV7 {
    let record = fixture(
      tailnetPort: tailnetPort,
      status: endedAt == nil ? .active : .ended,
      endedAt: endedAt,
      endReason: endedAt == nil ? nil : .unbound
    )
    try await database.write { db in
      try TailscaleBindingRecord.insert { record }.execute(db)
    }
    return record.id
  }
}
