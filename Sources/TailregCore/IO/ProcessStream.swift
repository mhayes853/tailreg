public enum ProcessStream: String, Sendable, Codable, CaseIterable, Equatable {
  case standardOutput = "stdout"
  case standardError = "stderr"
}
