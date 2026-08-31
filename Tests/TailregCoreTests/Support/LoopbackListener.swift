import Foundation
import TailregCore

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

final class LoopbackListener {
  enum Address {
    case loopbackV4
    case loopbackV6
    case wildcardV4
  }

  let port: PortNumber
  let descriptor: Int32

  init(_ address: Address = .loopbackV4, port requested: PortNumber? = nil) throws {
    #if canImport(Glibc)
      let socketType = Int32(SOCK_STREAM.rawValue)
    #else
      let socketType = SOCK_STREAM
    #endif

    let family = address == .loopbackV6 ? AF_INET6 : AF_INET
    let fileDescriptor = socket(family, socketType, 0)
    guard fileDescriptor >= 0 else { throw Failure.socket }

    var reuse: Int32 = 1
    setsockopt(
      fileDescriptor,
      SOL_SOCKET,
      SO_REUSEADDR,
      &reuse,
      socklen_t(MemoryLayout<Int32>.size)
    )
    if address == .loopbackV6 {
      // Keeps a v6 listener from also claiming the v4 port, so the two can be bound together.
      var only: Int32 = 1
      setsockopt(
        fileDescriptor,
        Int32(IPPROTO_IPV6),
        IPV6_V6ONLY,
        &only,
        socklen_t(MemoryLayout<Int32>.size)
      )
    }

    var storage = sockaddr_storage()
    let length: socklen_t
    switch address {
    case .loopbackV4, .wildcardV4:
      var v4 = sockaddr_in()
      v4.sin_family = sa_family_t(AF_INET)
      v4.sin_port = requested?.bigEndian ?? 0
      v4.sin_addr.s_addr =
        address == .wildcardV4 ? UInt32(0).bigEndian : UInt32(0x7F00_0001).bigEndian
      withUnsafeMutableBytes(of: &storage) { destination in
        withUnsafeBytes(of: &v4) { source in
          destination.copyMemory(from: source)
        }
      }
      length = socklen_t(MemoryLayout<sockaddr_in>.size)
    case .loopbackV6:
      var v6 = sockaddr_in6()
      v6.sin6_family = sa_family_t(AF_INET6)
      v6.sin6_port = requested?.bigEndian ?? 0
      v6.sin6_addr = in6addr_loopback
      withUnsafeMutableBytes(of: &storage) { destination in
        withUnsafeBytes(of: &v6) { source in
          destination.copyMemory(from: source)
        }
      }
      length = socklen_t(MemoryLayout<sockaddr_in6>.size)
    }

    let bound = withUnsafePointer(to: &storage) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fileDescriptor, $0, length)
      }
    }
    guard bound == 0, listen(fileDescriptor, 4) == 0 else {
      posixClose(fileDescriptor)
      throw Failure.bind
    }

    var assigned = sockaddr_storage()
    var assignedLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let named = withUnsafeMutablePointer(to: &assigned) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fileDescriptor, $0, &assignedLength)
      }
    }
    guard named == 0, let resolved = Self.port(of: assigned) else {
      posixClose(fileDescriptor)
      throw Failure.bind
    }

    descriptor = fileDescriptor
    port = resolved
  }

  func stop() {
    posixClose(descriptor)
  }

  private static func port(of storage: sockaddr_storage) -> PortNumber? {
    var storage = storage
    if storage.ss_family == sa_family_t(AF_INET6) {
      let raw = withUnsafeBytes(of: &storage) {
        $0.load(fromByteOffset: 0, as: sockaddr_in6.self).sin6_port
      }
      return PortNumber(bigEndian: raw)
    }
    let raw = withUnsafeBytes(of: &storage) {
      $0.load(fromByteOffset: 0, as: sockaddr_in.self).sin_port
    }
    return PortNumber(bigEndian: raw)
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
