import Foundation
import SQLiteData
import TailregCore

public struct ResolvedProject: Sendable {
  public let record: ProjectRecord
  public let root: URL
  public let specification: ProjectSpecification?

  public static func resolve(
    database: any DatabaseWriter,
    explicitPath: String?,
    currentDirectory: URL
  ) async throws
    -> Self
  {
    let root = try projectRoot(explicitPath: explicitPath, currentDirectory: currentDirectory)
    let configurationFile = root.appendingPathComponent("tailreg.toml")
    let specification =
      FileManager.default.fileExists(atPath: configurationFile.path)
      ? try ProjectSpecification.load(from: configurationFile)
      : nil
    let fallbackName = root.lastPathComponent.isEmpty ? "project" : root.lastPathComponent
    let name =
      (specification?.name?.trimmingCharacters(in: .whitespacesAndNewlines))
      .flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
    let rootPath = root.path

    let record = try await database.write { database in
      if var existing = try ProjectRecord.where({ $0.rootPath.eq(rootPath) }).fetchOne(database) {
        guard existing.name != name else { return existing }
        try ProjectRecord.find(existing.id)
          .update { $0.name = #bind(name) }
          .execute(database)
        existing.name = name
        return existing
      }
      let project = ProjectRecord(rootPath: rootPath, name: name)
      try ProjectRecord.insert { project }.execute(database)
      return project
    }
    return Self(record: record, root: root, specification: specification)
  }

  private static func projectRoot(explicitPath: String?, currentDirectory: URL) throws -> URL {
    if let explicitPath {
      let explicit = URL(fileURLWithPath: explicitPath, relativeTo: currentDirectory)
        .standardizedFileURL.resolvingSymlinksInPath()
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: explicit.path, isDirectory: &isDirectory) else {
        throw ProjectResolutionError(path: explicit.path)
      }
      return isDirectory.boolValue ? explicit : explicit.deletingLastPathComponent()
    }

    let start = currentDirectory.standardizedFileURL.resolvingSymlinksInPath()
    for component in ["tailreg.toml", ".git"] {
      if let root = ancestor(from: start, containing: component) { return root }
    }
    return start
  }

  private static func ancestor(from start: URL, containing component: String) -> URL? {
    var candidate = start
    while true {
      if FileManager.default.fileExists(
        atPath: candidate.appendingPathComponent(component).path
      ) {
        return candidate
      }
      let parent = candidate.deletingLastPathComponent()
      if parent.path == candidate.path { return nil }
      candidate = parent
    }
  }
}

public struct ProjectResolutionError: Error, CustomStringConvertible, Sendable {
  public let path: String
  public var description: String { "project path does not exist: \(path)" }
}
