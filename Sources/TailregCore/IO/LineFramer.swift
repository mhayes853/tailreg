import Foundation

struct LineFramer {
  private static let newline: UInt8 = 0x0A
  private static let carriageReturn: UInt8 = 0x0D

  private var carry: [UInt8] = []
  private let limit: Int

  init(limit: Int) {
    self.limit = limit
  }

  mutating func consume(_ data: Data) -> [String] {
    guard !data.isEmpty else { return [] }
    carry.append(contentsOf: data)

    var lines: [String] = []
    while let index = carry.firstIndex(of: Self.newline) {
      lines.append(Self.line(from: carry[..<index]))
      carry.removeFirst(index + 1)
    }
    while carry.count > limit {
      lines.append(Self.line(from: carry[..<limit]))
      carry.removeFirst(limit)
    }
    return lines
  }

  mutating func finish() -> String? {
    guard !carry.isEmpty else { return nil }
    defer { carry.removeAll() }
    return Self.line(from: carry[...])
  }

  private static func line(from bytes: ArraySlice<UInt8>) -> String {
    let trimmed = bytes.last == carriageReturn ? bytes.dropLast() : bytes
    let text = String(decoding: trimmed, as: UTF8.self)
    guard text.utf8.contains(carriageReturn) else { return text }
    let segments = text.split(separator: "\r", omittingEmptySubsequences: false)
    return segments.last { !$0.isEmpty }.map(String.init) ?? ""
  }
}
