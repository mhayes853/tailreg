import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

extension ProcessOutputFile {
  static func openable(at url: URL) -> ProcessOutputTarget {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return .unavailable(.inaccessible) }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      if url.path == "/dev/null" { return .unavailable(.nullDevice) }
      if url.path.hasPrefix("/dev/tty") || url.path.hasPrefix("/dev/pts/") {
        return .unavailable(.terminal)
      }
      return .unavailable(.nonRegularFile)
    }
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      return .unavailable(.inaccessible)
    }
    return .regularFile(
      ProcessOutputFile(
        url: url,
        identity: ProcessOutputFileIdentity(
          device: UInt64(info.st_dev),
          inode: UInt64(info.st_ino)
        )
      )
    )
  }
}
