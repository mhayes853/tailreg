import TailregCore

public struct StubPortProbe: PortProbe {
  /// Plain numbers: callers of this stub are testing tailscale behaviour, not port validity.
  public var listening: Set<Int>

  public init(listening: Set<Int> = []) {
    self.listening = listening
  }

  public func isListening(host: String, port: PortNumber) async -> Bool {
    listening.contains(port.intValue)
  }
}
