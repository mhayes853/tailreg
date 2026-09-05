import Foundation

/// The `tailreg` binary from the same build as the tests.
///
/// On Linux the test runner sits in the build directory, next to the binary. On macOS SwiftPM runs
/// the tests through `swiftpm-testing-helper`, which lives in the toolchain rather than the build
/// directory, so `argv[0]` says nothing about where the binary is; the bundle it was asked to load
/// does. Each candidate is walked outwards so neither layout has to be assumed exactly.
func builtTailregExecutable(named name: String = "tailreg") -> URL {
  firstExecutable(named: name, walkingUpFrom: buildDirectoryCandidates())
    // Returned rather than trapped so the caller's own precondition reports it in context.
    ?? URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .appendingPathComponent(name)
}

/// Walks outwards from each candidate looking for an executable of `name`.
func firstExecutable(named name: String, walkingUpFrom candidates: [URL]) -> URL? {
  for start in candidates {
    var directory = start
    for _ in 0..<6 {
      let candidate = directory.appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path || directory.path == "/" { break }
      directory = parent
    }
  }
  return nil
}

private func buildDirectoryCandidates() -> [URL] {
  var candidates: [URL] = []
  let arguments = CommandLine.arguments
  // `swiftpm-testing-helper --test-bundle-path <bundle>` names the build directory outright.
  if let flag = arguments.firstIndex(of: "--test-bundle-path"),
    arguments.indices.contains(flag + 1)
  {
    candidates.append(URL(fileURLWithPath: arguments[flag + 1]))
  }
  candidates += Bundle.allBundles
    .filter { $0.bundlePath.hasSuffix(".xctest") }
    .map(\.bundleURL)
  candidates.append(URL(fileURLWithPath: arguments[0]).deletingLastPathComponent())
  return candidates
}
