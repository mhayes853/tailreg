import Foundation

/// The `tailreg` binary from the same build as the tests.
///
/// On Linux the test runner sits directly in the build directory, next to the binary. On macOS it
/// sits inside `TailregPackageTests.xctest/Contents/MacOS`, so the binary is three directories up:
/// the search walks outwards rather than assuming either layout.
func builtTailregExecutable(named name: String = "tailreg") -> URL {
  var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
  for _ in 0..<6 {
    let candidate = directory.appendingPathComponent(name)
    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    directory.deleteLastPathComponent()
  }
  // Returned rather than trapped so the caller's own precondition reports it in context.
  return URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .appendingPathComponent(name)
}
