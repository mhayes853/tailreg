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
    let token = try await acquire(mode, isolation: isolation)
    let result = try await operation()
    _ = consume token
    return result
  }

  private func acquire(
    _ mode: Mode,
    isolation: isolated (any Actor)?
  ) async throws -> FileLockToken {
    try createLockDirectory()

    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else {
      throw TailscaleError.lockUnavailable(path: path, detail: Self.errorDescription())
    }
    let token = FileLockToken(descriptor: descriptor)

    var waited = Duration.zero
    while true {
      if flock(descriptor, mode.operation | LOCK_NB) == 0 { return token }

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
