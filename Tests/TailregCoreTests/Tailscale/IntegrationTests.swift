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
    try TailscaleBinder.standard(databasePath: temp.path("tailreg.sqlite"))
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
    #expect(binding.hostname.hasSuffix(".ts.net"))

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
    let alpha = try LoopbackListener()
    let beta = try LoopbackListener()
    defer {
      alpha.stop()
      beta.stop()
    }
    defer { Task { try? await binder.unbind(tailnetPort: Self.integrationPort) } }

    try await binder.bind(
      localPort: alpha.port,
      to: .explicit(Self.integrationPort),
      mountPath: "/alpha"
    )
    try await binder.bind(
      localPort: beta.port,
      to: .explicit(Self.integrationPort),
      mountPath: "/beta"
    )

    let both = try await binder.bindings().filter { $0.tailnetPort == Self.integrationPort }
    #expect(both.map(\.mountPath).sorted() == ["/alpha", "/beta"])

    try await binder.unbind(localPort: alpha.port)

    let survivors = try await binder.bindings().filter { $0.tailnetPort == Self.integrationPort }
    #expect(survivors.map(\.mountPath) == ["/beta"])
    #expect(survivors.map(\.localPort) == [beta.port])
  }
}
