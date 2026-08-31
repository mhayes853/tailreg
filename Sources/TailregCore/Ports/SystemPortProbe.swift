import Dispatch

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

private let portProbeQueue = DispatchQueue(
  label: "com.tailreg.ports.portprobe",
  attributes: .concurrent
)

public struct SystemPortProbe: PortProbe {
  public init() {}

  public func isListening(host: String, port: PortNumber) async -> Bool {
    await withCheckedContinuation { continuation in
      portProbeQueue.async {
        continuation.resume(returning: Self.connectSucceeds(host: host, port: port))
      }
    }
  }

  private static func connectSucceeds(host: String, port: PortNumber) -> Bool {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    #if canImport(Glibc)
      hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #else
      hints.ai_socktype = SOCK_STREAM
    #endif

    var resolved: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, port.description, &hints, &resolved) == 0, let head = resolved else {
      return false
    }
    defer { freeaddrinfo(resolved) }

    var candidate: UnsafeMutablePointer<addrinfo>? = head
    while let info = candidate {
      let descriptor = socket(
        info.pointee.ai_family,
        info.pointee.ai_socktype,
        info.pointee.ai_protocol
      )
      if descriptor >= 0 {
        let connected = connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
        close(descriptor)
        if connected { return true }
      }
      candidate = info.pointee.ai_next
    }
    return false
  }
}
