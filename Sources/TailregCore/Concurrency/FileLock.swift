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
    let token = try await acquire(mode, isolation: isolation)
    Self.debugLog("withLock(\(mode)) acquired")
    let result = try await operation()
    Self.debugLog("withLock(\(mode)) operation done")
    _ = consume token
    Self.debugLog("withLock(\(mode)) token consumed")
    return result
  }

  private func acquire(
    _ mode: Mode,
    isolation: isolated (any Actor)?
  ) async throws -> FileLockToken {
    Self.debugLog("acquire(\(mode)) createLockDirectory")
    try createLockDirectory()

    Self.debugLog("acquire(\(mode)) open")
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    Self.debugLog("acquire(\(mode)) opened fd=\(descriptor)")
    guard descriptor >= 0 else {
      throw TailscaleError.lockUnavailable(path: path, detail: Self.errorDescription())
    }
    let token = FileLockToken(descriptor: descriptor)

    var waited = Duration.zero
    while true {
      let rc = flock(descriptor, mode.operation | LOCK_NB)
      Self.debugLog("acquire(\(mode)) flock rc=\(rc) waited=\(waited)")
      if rc == 0 { return token }

      let code = errno
      guard code == EWOULDBLOCK || code == EINTR else {
        throw TailscaleError.lockUnavailable(path: path, detail: Self.errorDescription(code))
      }
      guard waited < timeout else {
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

struct FileLockToken: ~Copyable {
  private let descriptor: Int32

  fileprivate init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
