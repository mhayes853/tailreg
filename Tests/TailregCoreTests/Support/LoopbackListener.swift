import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

final class LoopbackListener {
  let port: Int
  private let descriptor: Int32

  init() throws {
    let fileDescriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    guard fileDescriptor >= 0 else { throw Failure.socket }

    var reuse: Int32 = 1
    setsockopt(
      fileDescriptor,
      SOL_SOCKET,
      SO_REUSEADDR,
      &reuse,
      socklen_t(MemoryLayout<Int32>.size)
    )

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian

    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fileDescriptor, 4) == 0 else {
      posixClose(fileDescriptor)
      throw Failure.bind
    }

    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &assigned) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fileDescriptor, $0, &length)
      }
    }
    guard named == 0 else {
      posixClose(fileDescriptor)
      throw Failure.bind
    }

    descriptor = fileDescriptor
    port = Int(UInt16(bigEndian: assigned.sin_port))
  }

  func stop() {
    posixClose(descriptor)
  }

  enum Failure: Error { case socket, bind }
}

private func posixClose(_ descriptor: Int32) {
  #if canImport(Glibc)
    _ = Glibc.close(descriptor)
  #else
    _ = Darwin.close(descriptor)
  #endif
}
