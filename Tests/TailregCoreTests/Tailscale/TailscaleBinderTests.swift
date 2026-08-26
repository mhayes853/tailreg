import Foundation
import TailregCore
import Testing

@Suite
struct `TailscaleBinder tests` {
  private struct Harness {
    let binder: TailscaleBinder
    let daemon: FakeTailscaleDaemon
    let registryPath: String
    let temp: TempDirectory
  }

  private func makeHarness(
    handlers: [FakeTailscaleDaemon.Handler] = [],
    listening: Set<Int> = [],
    backendState: String = "Running",
    serveFailure: (stderr: String, exitCode: Int32)? = nil,
    registryComponent: String = "bindings.json"
  ) throws -> Harness {
    let temp = try TempDirectory()
    let daemon = FakeTailscaleDaemon(
      handlers: handlers,
      backendState: backendState,
      serveFailure: serveFailure
    )
    let registryPath = temp.path(registryComponent)

    return Harness(
      binder: TailscaleBinder(
        binaryPath: "/usr/bin/tailscale",
        runner: daemon,
        portProbe: StubPortProbe(listening: listening),
        registryPath: registryPath
      ),
      daemon: daemon,
      registryPath: registryPath,
      temp: temp
    )
  }

  private func reopened(_ harness: Harness) -> TailscaleBinder {
    TailscaleBinder(
      binaryPath: "/usr/bin/tailscale",
      runner: harness.daemon,
      portProbe: StubPortProbe(),
      registryPath: harness.registryPath
    )
  }

  // MARK: - Binding

  @Test
  func `Binds A Live Local Port And Returns What The Daemon Recorded`() async throws {
    let harness = try makeHarness(listening: [3000])

    let binding = try await harness.binder.bind(localPort: 3000)

    #expect(binding.tailnetPort == 443)
    #expect(binding.localPort == 3000)
    #expect(binding.isManaged)
    #expect(binding.url?.absoluteString == "https://node.example.ts.net/")
    #expect(
      harness.daemon.argv(startingWith: ["serve", "--bg"]) == [
        ["serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:3000"]
      ]
    )
  }

  @Test
  func `Adds Set Path Only For A Non Root Mount Path`() async throws {
    let harness = try makeHarness(listening: [3000])

    try await harness.binder.bind(localPort: 3000, to: .explicit(8443), mountPath: "/api")

    #expect(
      harness.daemon.argv(startingWith: ["serve", "--bg"]) == [
        ["serve", "--bg", "--yes", "--https=8443", "--set-path=/api", "http://127.0.0.1:3000"]
      ]
    )
  }

  @Test
  func `Refuses To Bind A Port With Nothing Listening`() async throws {
    let harness = try makeHarness(listening: [])

    await #expect(throws: TailscaleError.noLocalServerListening(port: 3000)) {
      try await harness.binder.bind(localPort: 3000)
    }
    #expect(harness.daemon.configuredHandlers.isEmpty)
  }

  @Test
  func `Auto Allocation Takes The First Free Pool Port`() async throws {
    let harness = try makeHarness(
      handlers: [.init(tailnetPort: 443, localPort: 3773)],
      listening: [3000]
    )

    #expect(try await harness.binder.bind(localPort: 3000).tailnetPort == 8443)
  }

  @Test
  func `Auto Allocation Fails When Every Pool Port Is Taken`() async throws {
    let harness = try makeHarness(
      handlers: TailscaleTailnetPort.autoAllocationPool.map {
        .init(tailnetPort: $0, localPort: 9000)
      },
      listening: [3000]
    )

    await #expect(throws: TailscaleError.noAvailableTailnetPort) {
      try await harness.binder.bind(localPort: 3000)
    }
  }

  @Test
  func `Rejects An Explicit Port Already Serving The Same Mount Path`() async throws {
    let harness = try makeHarness(
      handlers: [.init(tailnetPort: 443, localPort: 3773)],
      listening: [3000]
    )

    await #expect(
      throws: TailscaleError.tailnetPortInUse(port: 443, existingTarget: "localPort(3773)")
    ) {
      try await harness.binder.bind(localPort: 3000, to: .explicit(443))
    }
  }

  @Test
  func `Hosts Several Local Servers On One Port Under Different Mount Paths`() async throws {
    let harness = try makeHarness(listening: [3000, 4000, 5000])

    try await harness.binder.bind(localPort: 3000, to: .explicit(443), mountPath: "/alpha")
    try await harness.binder.bind(localPort: 4000, to: .explicit(443), mountPath: "/beta")
    try await harness.binder.bind(localPort: 5000, to: .explicit(443), mountPath: "/gamma")

    let bindings = try await harness.binder.bindings()
    #expect(bindings.map(\.mountPath) == ["/alpha", "/beta", "/gamma"])
    #expect(bindings.map(\.localPort) == [3000, 4000, 5000])
    #expect(bindings.allSatisfy { $0.isManaged })
  }

  @Test
  func `Rolls Back The Claim When Serve Fails`() async throws {
    let harness = try makeHarness(
      listening: [3000],
      serveFailure: (stderr: "something unexpected", exitCode: 1)
    )

    await #expect(throws: TailscaleError.self) {
      try await harness.binder.bind(localPort: 3000)
    }

    harness.daemon.addHandlerExternally(.init(tailnetPort: 443, localPort: 3000))
    #expect(try await harness.binder.bindings().allSatisfy { $0.isManaged == false })
  }

  @Test
  func `Refuses To Bind While The Daemon Is Not Running`() async throws {
    let harness = try makeHarness(listening: [3000], backendState: "Stopped")

    await #expect(throws: TailscaleError.daemonNotRunning(state: "Stopped")) {
      try await harness.binder.bind(localPort: 3000)
    }
    #expect(harness.daemon.configuredHandlers.isEmpty)
  }

  @Test
  func `Serialises Concurrent Binds So They Cannot Claim The Same Port`() async throws {
    let harness = try makeHarness(listening: [3000, 4000])
    let binder = harness.binder

    async let first = binder.bind(localPort: 3000)
    async let second = binder.bind(localPort: 4000)
    let bound = try await [first, second]

    #expect(Set(bound.map(\.tailnetPort)) == [443, 8443])
    #expect(harness.daemon.configuredHandlers.count == 2)
  }

  // MARK: - Ownership

  @Test
  func `Reports Handlers Tailreg Never Created As Foreign`() async throws {
    let harness = try makeHarness(handlers: [.init(tailnetPort: 443, localPort: 3773)])

    let bindings = try await harness.binder.bindings()

    #expect(bindings.count == 1)
    #expect(bindings[0].isManaged == false)
  }

  @Test
  func `Remembers Ownership Across Binder Instances`() async throws {
    let harness = try makeHarness(listening: [3000])
    try await harness.binder.bind(localPort: 3000)

    let bindings = try await reopened(harness).bindings()

    #expect(bindings.count == 1)
    #expect(bindings[0].isManaged)
  }

  @Test
  func `Discards A Claim Whose Handler Vanished`() async throws {
    let harness = try makeHarness(listening: [3000])
    try await harness.binder.bind(localPort: 3000)

    harness.daemon.removeAllHandlersExternally()
    _ = try await harness.binder.bindings()
    harness.daemon.addHandlerExternally(.init(tailnetPort: 443, localPort: 3000))

    #expect(try await harness.binder.bindings().allSatisfy { $0.isManaged == false })
  }

  @Test
  func `Does Not Extend A Claim To Another Mount Path On The Same Port`() async throws {
    let harness = try makeHarness(listening: [3000])
    try await harness.binder.bind(localPort: 3000, to: .explicit(443))
    harness.daemon.addHandlerExternally(
      .init(tailnetPort: 443, mountPath: "/api", localPort: 9999)
    )

    let bindings = try await harness.binder.bindings()

    #expect(bindings.first { $0.mountPath == "/" }?.isManaged == true)
    #expect(bindings.first { $0.mountPath == "/api" }?.isManaged == false)
  }

  @Test
  func `Creates The Registry Directory On First Bind`() async throws {
    let harness = try makeHarness(
      listening: [3000],
      registryComponent: "nested/deeper/bindings.json"
    )

    try await harness.binder.bind(localPort: 3000)

    #expect(FileManager.default.fileExists(atPath: harness.registryPath))
  }

  @Test
  func `Fails Loudly On A Corrupt Registry Rather Than Discarding Ownership`() async throws {
    let harness = try makeHarness()
    try Data("{ truncated".utf8).write(to: URL(fileURLWithPath: harness.registryPath))

    await #expect(throws: TailscaleError.self) {
      try await harness.binder.bindings()
    }
  }

  // MARK: - Unbinding

  @Test
  func `Unbinding By Local Port Removes Every Handler Pointing At It`() async throws {
    let harness = try makeHarness(
      handlers: [
        .init(tailnetPort: 443, localPort: 3000),
        .init(tailnetPort: 8443, localPort: 3000),
        .init(tailnetPort: 10000, localPort: 4000)
      ]
    )

    let removed = try await harness.binder.unbind(localPort: 3000)

    #expect(removed.map(\.tailnetPort) == [443, 8443])
    #expect(harness.daemon.configuredHandlers.map(\.tailnetPort) == [10000])
  }

  @Test
  func `Unbinding By Tailnet Port Honours Foreign Handlers`() async throws {
    let harness = try makeHarness(handlers: [.init(tailnetPort: 443, localPort: 3773)])

    let removed = try await harness.binder.unbind(tailnetPort: 443)

    #expect(removed.count == 1)
    #expect(removed[0].isManaged == false)
    #expect(harness.daemon.configuredHandlers.isEmpty)
  }

  @Test
  func `Removes One Mount Path Without Disturbing The Others`() async throws {
    let harness = try makeHarness(listening: [3000, 4000])
    try await harness.binder.bind(localPort: 3000, to: .explicit(443), mountPath: "/alpha")
    try await harness.binder.bind(localPort: 4000, to: .explicit(443), mountPath: "/beta")

    let removed = try await harness.binder.unbind(localPort: 3000)

    #expect(removed.map(\.mountPath) == ["/alpha"])
    #expect(
      harness.daemon.argv(startingWith: ["serve", "--https=443"]) == [
        ["serve", "--https=443", "--set-path=/alpha", "off"]
      ]
    )
    #expect(try await harness.binder.bindings().map(\.mountPath) == ["/beta"])
  }

  @Test
  func `Unbind All Leaves Handlers Tailreg Did Not Create Alone`() async throws {
    let harness = try makeHarness(
      handlers: [.init(tailnetPort: 443, localPort: 3773)],
      listening: [3000]
    )
    try await harness.binder.bind(localPort: 3000, to: .explicit(8443))

    let removed = try await harness.binder.unbindAll()

    #expect(removed.map(\.tailnetPort) == [8443])
    #expect(harness.daemon.configuredHandlers.map(\.tailnetPort) == [443])
    #expect(harness.daemon.argvHistory.allSatisfy { $0 != ["serve", "reset"] })
  }

  @Test
  func `Unbinding Something That Is Not There Is A No Op`() async throws {
    let harness = try makeHarness()

    #expect(try await harness.binder.unbind(localPort: 9999).isEmpty)
    #expect(harness.daemon.argv(startingWith: ["serve", "--https"]).isEmpty)
  }
}
