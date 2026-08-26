import TailregCore
import Testing

@Suite
struct `SystemPortProbe tests` {
  private let probe = SystemPortProbe()

  @Test
  func `Detects A Live Loopback Listener`() async throws {
    let listener = try LoopbackListener()
    defer { listener.stop() }

    #expect(await probe.isListening(port: listener.port))
  }

  @Test
  func `Reports Nothing Once The Listener Closes`() async throws {
    let listener = try LoopbackListener()
    let port = listener.port
    listener.stop()

    #expect(await probe.isListening(port: port) == false)
  }
}
