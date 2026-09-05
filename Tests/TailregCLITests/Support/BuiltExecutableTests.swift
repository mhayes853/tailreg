import Foundation
import Testing

/// macOS runs the tests out of a bundle that sits several directories below the built binary, and
/// through a helper in the toolchain rather than the build directory. Both layouts are checked
/// here so the difference is caught without a macOS runner.
@Suite(.timeLimit(.minutes(1)))
struct `Built executable lookup tests` {
  @Test
  func `Finds the binary beside a Linux style test runner`() throws {
    let build = try BuildDirectory()
    defer { build.cleanUp() }

    let found = firstExecutable(named: "tailreg", walkingUpFrom: [build.root])

    #expect(found?.path == build.executable.path)
  }

  @Test
  func `Finds the binary from inside a macOS test bundle`() throws {
    let build = try BuildDirectory()
    defer { build.cleanUp() }
    let bundle = build.root.appendingPathComponent("TailregPackageTests.xctest")
    let runner = bundle.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: runner, withIntermediateDirectories: true)

    #expect(
      firstExecutable(named: "tailreg", walkingUpFrom: [bundle])?.path == build.executable.path
    )
    #expect(
      firstExecutable(named: "tailreg", walkingUpFrom: [runner])?.path == build.executable.path
    )
  }

  @Test
  func `Reports nothing rather than walking out of the filesystem`() throws {
    let build = try BuildDirectory()
    defer { build.cleanUp() }

    #expect(firstExecutable(named: "not-a-product", walkingUpFrom: [build.root]) == nil)
    #expect(firstExecutable(named: "tailreg", walkingUpFrom: [URL(fileURLWithPath: "/")]) == nil)
  }

  private struct BuildDirectory {
    let root: URL
    let executable: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailreg-build-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      executable = root.appendingPathComponent("tailreg")
      FileManager.default.createFile(
        atPath: executable.path,
        contents: Data(),
        attributes: [.posixPermissions: 0o755]
      )
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }
  }
}
