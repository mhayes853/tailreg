import Foundation

struct StatusJSONRenderer: Sendable {
  func render(_ report: StatusReport) throws -> String {
    let encoder = JSONEncoder()
    // Sorted keys because synthesized `Codable` does not preserve declaration order, and an
    // arbitrary order would make two reports of the same state diff against each other. Slashes
    // are left alone so URLs and paths stay readable to whoever is reading the dump.
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(report), as: UTF8.self)
  }
}
