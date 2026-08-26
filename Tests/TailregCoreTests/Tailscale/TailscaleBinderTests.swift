import Foundation
import TailregCore
import Testing

@Suite
struct `TailscaleBinder tests` {
  private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

  private struct Harness {
    let binder: TailscaleBinder
    let daemon: FakeTailscaleDaemon
    let registry: TailscaleBindingRegistry
    let temp: TempDirectory
  }

  private func makeHarness(
    handlers: [FakeTailscaleDaemon.Handler] = [],
    listening: Set<Int> = [],
    backendState: String = "Running",
    serveFailure: (stderr: String, exitCode: Int32)? = nil
  ) throws -> Harness {
    let temp = try TempDirectory()
    let daemon = FakeTailscaleDaemon(
      handlers: handlers,
      backendState: backendState,
      serveFailure: serveFailure
    )
    let registry = TailscaleBindingRegistry(path: temp.path("bindings.json"))

    return Harness(
      binder: TailscaleBinder(
        cli: TailscaleCLI(binaryPath: "/usr/bin/tailscale", runner: daemon),
        portProbe: StubPortProbe(listening: listening),
        registry: registry,
        now: { self.fixedDate }
      ),
      daemon: daemon,
      registry: registry,
      temp: temp
    )
  }

  private func claim(
    localPort: Int,
    tailnetPort: Int,
    mountPath: String = "/"
  ) -> TailscaleBindingRecord {
    TailscaleBindingRecord(
      localPort: localPort,
      tailnetPort: tailnetPort,
      proto: .https,
      mountPath: mountPath,
      createdAt: fixedDate
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
    #expect(try await harness.registry.records() == [claim(localPort: 3000, tailnetPort: 443)])
  }

  @Test
  func `Refuses To Bind A Port With Nothing Listening`() async throws {
    let harness = try makeHarness(listening: [])

    await #expect(throws: TailscaleError.noLocalServerListening(port: 3000)) {
      try await harness.binder.bind(localPort: 3000)
    }
    #expect(harness.daemon.configuredHandlers.isEmpty)
    #expect(try await harness.registry.records().isEmpty)
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
  func `Shares An Explicit Port When The Mount Path Differs`() async throws {
    let harness = try makeHarness(
      handlers: [.init(tailnetPort: 443, localPort: 3773)],
      listening: [3000]
    )

    let binding = try await harness.binder.bind(
      localPort: 3000,
      to: .explicit(443),
      mountPath: "/api"
    )

    #expect(binding.mountPath == "/api")
    #expect(binding.localPort == 3000)
    #expect(harness.daemon.configuredHandlers.count == 2)
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
    #expect(try await harness.registry.records().isEmpty)
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
    #expect(try await harness.registry.records().count == 2)
  }

  // MARK: - Inspection

  @Test
  func `Reports Handlers Tailreg Never Created As Foreign`() async throws {
    let harness = try makeHarness(handlers: [.init(tailnetPort: 443, localPort: 3773)])

    let bindings = try await harness.binder.bindings()

    #expect(bindings.count == 1)
    #expect(bindings[0].isManaged == false)
    #expect(try await harness.binder.managedBindings().isEmpty)
  }

  @Test
  func `Discards A Claim Whose Handler Vanished`() async throws {
    let harness = try makeHarness()
    try await harness.registry.add(claim(localPort: 3000, tailnetPort: 443))

    _ = try await harness.binder.bindings()

    #expect(try await harness.registry.records().isEmpty)
  }

  @Test
  func `Keeps A Claim That Still Matches A Live Handler`() async throws {
    let harness = try makeHarness(handlers: [.init(tailnetPort: 443, localPort: 3000)])
    try await harness.registry.add(claim(localPort: 3000, tailnetPort: 443))

    #expect(try await harness.binder.bindings()[0].isManaged)
    #expect(try await harness.registry.records().count == 1)
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
  func `Unbind All Leaves Handlers Tailreg Did Not Create Alone`() async throws {
    let harness = try makeHarness(
      handlers: [
        .init(tailnetPort: 443, localPort: 3773),
        .init(tailnetPort: 8443, localPort: 3000)
      ]
    )
    try await harness.registry.add(claim(localPort: 3000, tailnetPort: 8443))

    let removed = try await harness.binder.unbindAll()

    #expect(removed.map(\.tailnetPort) == [8443])
    #expect(harness.daemon.configuredHandlers.map(\.tailnetPort) == [443])
    #expect(try await harness.registry.records().isEmpty)
    #expect(harness.daemon.argvHistory.allSatisfy { $0 != ["serve", "reset"] })
  }

  @Test
  func `Unbinding Something That Is Not There Is A No Op`() async throws {
    let harness = try makeHarness()

    #expect(try await harness.binder.unbind(localPort: 9999).isEmpty)
    #expect(harness.daemon.argv(startingWith: ["serve", "--https"]).isEmpty)
  }
}
