import Dispatch

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

// MARK: - Protocol

public protocol PortProbe: Sendable {
  func isListening(host: String, port: Int) async -> Bool
}

extension PortProbe {
  public func isListening(port: Int) async -> Bool {
    await isListening(host: "127.0.0.1", port: port)
  }
}

// MARK: - System implementation

private let portProbeQueue = DispatchQueue(
  label: "com.tailreg.io.portprobe",
  attributes: .concurrent
)

public struct SystemPortProbe: PortProbe {
  public init() {}

  public func isListening(host: String, port: Int) async -> Bool {
    await withCheckedContinuation { continuation in
      portProbeQueue.async {
        continuation.resume(returning: Self.connectSucceeds(host: host, port: port))
      }
    }
  }

  private static func connectSucceeds(host: String, port: Int) -> Bool {
    guard port > 0, port <= 65535 else { return false }

    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    #if canImport(Glibc)
      hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #else
      hints.ai_socktype = SOCK_STREAM
    #endif

    var resolved: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &resolved) == 0, let head = resolved else {
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
