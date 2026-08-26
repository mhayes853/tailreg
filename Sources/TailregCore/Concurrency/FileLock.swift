import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct FileLock: Sendable {
  enum Mode {
    case shared
    case exclusive

    fileprivate var operation: Int32 {
      switch self {
      case .shared: LOCK_SH
      case .exclusive: LOCK_EX
      }
    }
  }

  let path: String
  var timeout: Duration = .seconds(10)
  var pollInterval: Duration = .milliseconds(25)

  init(path: String) {
    self.path = path
  }

  func withLock<T>(
    _ mode: Mode,
    isolation: isolated (any Actor)? = #isolation,
    _ operation: () async throws -> T
  ) async throws -> T {
    Self.debugLog("withLock(\(mode)) enter")
    let descriptor = try await acquire(mode, isolation: isolation)
    Self.debugLog("withLock(\(mode)) acquired")
    defer {
      flock(descriptor, LOCK_UN)
      close(descriptor)
      Self.debugLog("withLock(\(mode)) released")
    }
    let result = try await operation()
    Self.debugLog("withLock(\(mode)) operation done")
    return result
  }

  private func acquire(
    _ mode: Mode,
    isolation: isolated (any Actor)?
  ) async throws -> Int32 {
    Self.debugLog("acquire(\(mode)) createLockDirectory")
    try createLockDirectory()

    Self.debugLog("acquire(\(mode)) open")
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    Self.debugLog("acquire(\(mode)) opened fd=\(descriptor)")
    guard descriptor >= 0 else {
      throw TailscaleError.lockUnavailable(path: path, detail: Self.errorDescription())
    }

    var waited = Duration.zero
    while true {
      let rc = flock(descriptor, mode.operation | LOCK_NB)
      Self.debugLog("acquire(\(mode)) flock rc=\(rc) waited=\(waited)")
      if rc == 0 { return descriptor }

      let code = errno
      guard code == EWOULDBLOCK || code == EINTR else {
        close(descriptor)
        throw TailscaleError.lockUnavailable(path: path, detail: Self.errorDescription(code))
      }
      guard waited < timeout else {
        close(descriptor)
        throw TailscaleError.lockUnavailable(
          path: path,
          detail: "timed out after \(timeout) waiting for another tailreg process"
        )
      }

      Self.debugLog("acquire(\(mode)) sleeping \(pollInterval)")
      try await Task.sleep(for: pollInterval)
      Self.debugLog("acquire(\(mode)) woke")
      waited += pollInterval
    }
  }

  private static func debugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["TAILREG_FILELOCK_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data("[FileLock pid=\(getpid())] \(message)\n".utf8))
  }

  private func createLockDirectory() throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    guard !FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private static func errorDescription(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
  }
}
