import Foundation

public final class TempDirectory {
  public let url: URL

  public init() throws {
    url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("tailreg-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  public func path(_ component: String) -> String {
    url.appendingPathComponent(component).path
  }

  @discardableResult
  public func makeExecutable(_ component: String) -> String {
    let path = self.path(component)
    FileManager.default.createFile(
      atPath: path,
      contents: Data("#!/bin/sh\n".utf8),
      attributes: [.posixPermissions: 0o755]
    )
    return path
  }

  @discardableResult
  public func makeFile(_ component: String, contents: String) throws -> String {
    let path = self.path(component)
    try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    return path
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
