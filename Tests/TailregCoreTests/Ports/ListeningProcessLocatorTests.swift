import Foundation
import TailregCore
import Testing

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

@Suite(.timeLimit(.minutes(1)))
struct `SystemListeningProcessLocator tests` {
  private let locator = SystemListeningProcessLocator()

  // MARK: - This process

  @Test
  func `Finds This Process Holding A Loopback Listener`() async throws {
    let listener = try LoopbackListener()
    defer { listener.stop() }

    let found = try await locator.processes(listeningOn: listener.port)

    #expect(found.map(\.pid) == [getpid()])
    #expect(found.first?.hosts == ["127.0.0.1"])
  }

  @Test
  func `Reports Nothing Once The Listener Closes`() async throws {
    let listener = try LoopbackListener()
    let port = listener.port
    listener.stop()

    #expect(try await locator.processes(listeningOn: port).isEmpty)
  }

  @Test
  func `Reports Nothing For A PortNumber With No Listener`() async throws {
    let listener = try LoopbackListener()
    let port = listener.port
    listener.stop()

    #expect(try await locator.processes(listeningOn: port).isEmpty)
  }

  @Test
  func `Reports The Owning User`() async throws {
    let listener = try LoopbackListener()
    defer { listener.stop() }

    let found = try await locator.processes(listeningOn: listener.port)

    #expect(found.first?.userID == getuid())
  }

  // MARK: - Address families

  @Test
  func `Finds A Listener Bound To The IPv6 Loopback`() async throws {
    let listener = try LoopbackListener(.loopbackV6)
    defer { listener.stop() }

    let found = try await locator.processes(listeningOn: listener.port)

    #expect(found.map(\.pid) == [getpid()])
    #expect(found.first?.hosts == ["::1"])
  }

  @Test
  func `Finds A Listener Bound To The IPv4 Wildcard`() async throws {
    let listener = try LoopbackListener(.wildcardV4)
    defer { listener.stop() }

    let found = try await locator.processes(listeningOn: listener.port)

    #expect(found.map(\.pid) == [getpid()])
    #expect(found.first?.hosts == ["0.0.0.0"])
  }

  @Test
  func `Reports Both Hosts For A Listener On Each Family`() async throws {
    let (v4, v6) = try Self.pairAcrossFamilies()
    defer {
      v4.stop()
      v6.stop()
    }

    let found = try await locator.processes(listeningOn: v4.port)

    #expect(found.map(\.pid) == [getpid()])
    #expect(found.first?.hosts == ["127.0.0.1", "::1"])
  }

  // MARK: - Other processes

  @Test
  func `Attributes A Socket Held Only By A Child Process`() async throws {
    let holder = try SocketHoldingProcess()
    defer { holder.stop() }

    let found = try await settled(on: holder.port) { $0.map(\.pid) == [holder.pid] }

    #expect(found.map(\.pid) == [holder.pid])
  }

  @Test
  func `Reports The Child Name And Parent For An Inherited Socket`() async throws {
    let holder = try SocketHoldingProcess()
    defer { holder.stop() }

    let found = try await settled(on: holder.port) { $0.first?.name == "sleep" }

    #expect(found.first?.name == "sleep")
    #expect(found.first?.parentPID == getpid())
  }

  // MARK: - Filtering

  @Test
  func `Ignores Established Connections On The Same PortNumber`() async throws {
    let listener = try LoopbackListener()
    let port = listener.port
    let client = try Self.openConnection(to: port)
    let accepted = accept(listener.descriptor, nil, nil)
    defer {
      close(client)
      if accepted >= 0 { close(accepted) }
    }
    #expect(accepted >= 0)

    // The accepted socket keeps the port as its local address, but nothing is listening.
    listener.stop()

    #expect(try await locator.processes(listeningOn: port).isEmpty)
  }

  @Test
  func `Survives Processes Exiting During A Scan`() async throws {
    let listener = try LoopbackListener()
    defer { listener.stop() }

    let churn = Task.detached {
      for _ in 0..<30 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.01"]
        try? process.run()
        process.waitUntilExit()
      }
    }
    defer { churn.cancel() }

    for _ in 0..<10 {
      #expect(try await locator.processes(listeningOn: listener.port).map(\.pid) == [getpid()])
    }
    await churn.value
  }

  // MARK: - Helpers

  /// Retries until the child is visible: a spawned process is reachable through the port
  /// immediately, but its name and descriptor table land a moment later.
  private func settled(
    on port: PortNumber,
    until predicate: ([ListeningProcess]) -> Bool
  ) async throws -> [ListeningProcess] {
    for _ in 0..<50 {
      let found = try await locator.processes(listeningOn: port)
      if predicate(found) { return found }
      try await Task.sleep(for: .milliseconds(20))
    }
    return try await locator.processes(listeningOn: port)
  }

  /// Binds the same port on both families. The v4 listener picks the port, so the v6 bind can
  /// lose a race with an unrelated process and is retried.
  private static func pairAcrossFamilies() throws -> (LoopbackListener, LoopbackListener) {
    for _ in 0..<10 {
      let v4 = try LoopbackListener()
      if let v6 = try? LoopbackListener(.loopbackV6, port: v4.port) {
        return (v4, v6)
      }
      v4.stop()
    }
    throw LoopbackListener.Failure.bind
  }

  private static func openConnection(to port: PortNumber) throws -> Int32 {
    #if canImport(Glibc)
      let socketType = Int32(SOCK_STREAM.rawValue)
    #else
      let socketType = SOCK_STREAM
    #endif
    let descriptor = socket(AF_INET, socketType, 0)
    guard descriptor >= 0 else { throw LoopbackListener.Failure.socket }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian

    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else {
      close(descriptor)
      throw LoopbackListener.Failure.bind
    }
    return descriptor
  }
}
