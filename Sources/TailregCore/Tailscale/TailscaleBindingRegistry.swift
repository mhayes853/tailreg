import Foundation

public actor TailscaleBindingRegistry {
  static let currentVersion = 1

  public let path: String
  private let fileManager = FileManager.default

  public init(path: String = TailscaleBindingRegistry.defaultPath()) {
    self.path = path
  }

  // MARK: - Access

  public func records() throws -> [TailscaleBindingRecord] {
    guard let data = fileManager.contents(atPath: path), !data.isEmpty else { return [] }
    do {
      return try Self.decoder.decode(Envelope.self, from: data).bindings
    } catch {
      throw TailscaleError.registryCorrupt(path: path, detail: String(describing: error))
    }
  }

  public func add(_ record: TailscaleBindingRecord) throws {
    var current = try records()
    current.removeAll {
      $0.tailnetPort == record.tailnetPort
        && $0.proto == record.proto
        && $0.mountPath == record.mountPath
    }
    current.append(record)
    try replaceAll(with: current)
  }

  public func removeClaim(
    tailnetPort: Int,
    proto: TailscaleServeProtocol,
    mountPath: String
  ) throws {
    let remaining = try records()
      .filter {
        !($0.tailnetPort == tailnetPort && $0.proto == proto && $0.mountPath == mountPath)
      }
    try replaceAll(with: remaining)
  }

  public func replaceAll(with records: [TailscaleBindingRecord]) throws {
    let data = try Self.encoder.encode(
      Envelope(version: Self.currentVersion, bindings: records)
    )
    let directory = (path as NSString).deletingLastPathComponent
    if !directory.isEmpty, !fileManager.fileExists(atPath: directory) {
      try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  // MARK: - Storage

  private struct Envelope: Codable {
    let version: Int
    let bindings: [TailscaleBindingRecord]
  }

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  public static func defaultPath(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    let home = environment["HOME"] ?? NSHomeDirectory()
    #if os(macOS)
      return "\(home)/Library/Application Support/tailreg/bindings.json"
    #else
      let stateHome =
        environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.local/state"
      return "\(stateHome)/tailreg/bindings.json"
    #endif
  }
}
