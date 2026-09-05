import Foundation
import SQLiteData
import TailregCore

/// What is known about a directory, whether or not Tailreg has ever run there.
///
/// A project that was never brought up still has a shape — a root, a name, and whatever
/// `tailreg.toml` configures — and a command that only observes should be able to report it
/// without writing a record to say it looked.
public struct InspectedProject: Sendable {
  public let record: ProjectRecord?
  public let root: URL
  public let specification: ProjectSpecification?

  public var name: String {
    if let record { return record.name }
    return ResolvedProject.name(of: specification, at: root)
  }
}

public struct ResolvedProject: Sendable {
  public let record: ProjectRecord
  public let root: URL
  public let specification: ProjectSpecification?

  /// Reads a directory without recording that it was read.
  public static func inspect(
    database: any DatabaseWriter,
    explicitPath: String?,
    currentDirectory: URL
  ) async throws -> InspectedProject {
    let root = try projectRoot(explicitPath: explicitPath, currentDirectory: currentDirectory)
    let rootPath = root.path
    let record = try await database.read { database in
      try ProjectRecord.where { $0.rootPath.eq(rootPath) }.fetchOne(database)
    }
    return InspectedProject(
      record: record,
      root: root,
      specification: try specification(at: root)
    )
  }

  /// Finds an already-known project without creating one.
  ///
  /// Commands that act on observed runtime state must not bring a project into existence just by
  /// being run somewhere. A directory that was never brought up has nothing to report on, which
  /// is a `nil` rather than a new row.
  public static func lookUp(
    database: any DatabaseWriter,
    explicitPath: String?,
    currentDirectory: URL
  ) async throws -> Self? {
    let inspected = try await inspect(
      database: database,
      explicitPath: explicitPath,
      currentDirectory: currentDirectory
    )
    guard let record = inspected.record else { return nil }
    return Self(
      record: record,
      root: inspected.root,
      specification: inspected.specification
    )
  }

  public static func resolve(
    database: any DatabaseWriter,
    explicitPath: String?,
    currentDirectory: URL
  ) async throws
    -> Self
  {
    let root = try projectRoot(explicitPath: explicitPath, currentDirectory: currentDirectory)
    let specification = try specification(at: root)
    let name = name(of: specification, at: root)
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

  /// The project's name: what `tailreg.toml` calls it, else the directory it lives in.
  static func name(of specification: ProjectSpecification?, at root: URL) -> String {
    let fallback = root.lastPathComponent.isEmpty ? "project" : root.lastPathComponent
    return (specification?.name?.trimmingCharacters(in: .whitespacesAndNewlines))
      .flatMap { $0.isEmpty ? nil : $0 } ?? fallback
  }

  private static func specification(at root: URL) throws -> ProjectSpecification? {
    let configurationFile = root.appendingPathComponent("tailreg.toml")
    guard FileManager.default.fileExists(atPath: configurationFile.path) else { return nil }
    return try ProjectSpecification.load(from: configurationFile)
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
      // Darwin walks *past* the root by appending "..", so the parent never repeats itself and
      // the walk would run forever, building a longer path every time. The root is the stop.
      guard candidate.path != "/" else { return nil }
      let parent = candidate.deletingLastPathComponent().standardizedFileURL
      guard parent.path != candidate.path else { return nil }
      candidate = parent
    }
  }
}

public struct ProjectResolutionError: Error, CustomStringConvertible, Sendable {
  public let path: String
  public var description: String { "project path does not exist: \(path)" }
}
