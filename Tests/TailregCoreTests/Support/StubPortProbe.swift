import TailregCore

struct StubPortProbe: PortProbe {
  /// Plain numbers: callers of this stub are testing tailscale behaviour, not port validity.
  var listening: Set<Int>

  init(listening: Set<Int> = []) {
    self.listening = listening
  }

  func isListening(host: String, port: PortNumber) async -> Bool {
    listening.contains(port.intValue)
  }
}
