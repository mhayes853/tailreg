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
    let descriptor = try await acquire(mode, isolation: isolation)
    defer {
      flock(descriptor, LOCK_UN)
      close(descriptor)
    }
    return try await operation()
  }

  private func acquire(
    _ mode: Mode,
    isolation: isolated (any Actor)?
  ) async throws -> Int32 {
    try createLockDirectory()

    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else {
      throw TailscaleError.lockUnavailable(path: path, detail: Self.errorDescription())
    }

    var waited = Duration.zero
    while true {
      if flock(descriptor, mode.operation | LOCK_NB) == 0 { return descriptor }

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

      try await Task.sleep(for: pollInterval)
      waited += pollInterval
    }
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
