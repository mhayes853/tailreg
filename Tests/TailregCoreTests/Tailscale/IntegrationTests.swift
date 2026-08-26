import Foundation
import TailregCore
import Testing

@Suite(
  .enabled(if: ProcessInfo.processInfo.environment["TAILREG_INTEGRATION"] == "1"),
  .serialized
)
struct `Tailscale integration tests` {
  static let integrationPort = 10000

  private func makeBinder(_ temp: TempDirectory) throws -> TailscaleBinder {
    try TailscaleBinder.standard(registryPath: temp.path("bindings.json"))
  }

  @Test
  func `Detects The Installation And Reads Node Status`() async throws {
    let temp = try TempDirectory()

    let installation = try await makeBinder(temp).installation()

    #expect(installation.binaryPath.hasSuffix("tailscale"))
    #expect(!installation.version.isEmpty)
    #expect(!installation.dnsName.hasSuffix("."))
  }

  @Test
  func `Reads Existing Configuration Without Claiming It`() async throws {
    let temp = try TempDirectory()
    let binder = try makeBinder(temp)

    let before = try await binder.bindings()
    let after = try await binder.bindings()

    #expect(before.map(\.tailnetPort) == after.map(\.tailnetPort))
    #expect(before.allSatisfy { $0.isManaged == false })
  }

  @Test
  func `Binds And Unbinds A Real Local Server`() async throws {
    let temp = try TempDirectory()
    let binder = try makeBinder(temp)
    let listener = try LoopbackListener()
    defer { listener.stop() }

    let binding = try await binder.bind(
      localPort: listener.port,
      to: .explicit(Self.integrationPort)
    )

    #expect(binding.tailnetPort == Self.integrationPort)
    #expect(binding.localPort == listener.port)
    #expect(binding.isManaged)
    #expect(try await binder.managedBindings().contains { $0.tailnetPort == Self.integrationPort })

    let removed = try await binder.unbind(tailnetPort: Self.integrationPort)

    #expect(removed.count == 1)
    #expect(try await binder.bindings().allSatisfy { $0.tailnetPort != Self.integrationPort })
  }

  @Test
  func `Refuses A Local Port With Nothing Listening`() async throws {
    let temp = try TempDirectory()
    let listener = try LoopbackListener()
    let deadPort = listener.port
    listener.stop()

    await #expect(throws: TailscaleError.noLocalServerListening(port: deadPort)) {
      try await makeBinder(temp).bind(localPort: deadPort, to: .explicit(Self.integrationPort))
    }
  }

  @Test
  func `Removing One Mount Path Leaves The Others On That Port Intact`() async throws {
    let temp = try TempDirectory()
    let binder = try makeBinder(temp)
    let listener = try LoopbackListener()
    defer { listener.stop() }

    try await binder.bind(
      localPort: listener.port,
      to: .explicit(Self.integrationPort),
      mountPath: "/alpha"
    )
    try await binder.bind(
      localPort: listener.port,
      to: .explicit(Self.integrationPort),
      mountPath: "/beta"
    )

    let both = try await binder.bindings().filter { $0.tailnetPort == Self.integrationPort }
    #expect(both.map(\.mountPath).sorted() == ["/alpha", "/beta"])

    let cli = TailscaleCLI(
      binaryPath: try TailscaleLocator().locate(),
      runner: SystemProcessRunner()
    )
    try await cli.serveOff(tailnetPort: Self.integrationPort, proto: .https, mountPath: "/alpha")

    let survivors = try await binder.bindings().filter { $0.tailnetPort == Self.integrationPort }
    #expect(survivors.map(\.mountPath) == ["/beta"])

    try await binder.unbind(tailnetPort: Self.integrationPort)
  }
}
