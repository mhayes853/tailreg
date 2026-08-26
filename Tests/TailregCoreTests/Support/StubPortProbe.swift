import TailregCore

struct StubPortProbe: PortProbe {
  var listening: Set<Int>

  init(listening: Set<Int> = []) {
    self.listening = listening
  }

  func isListening(host: String, port: Int) async -> Bool {
    listening.contains(port)
  }
}
