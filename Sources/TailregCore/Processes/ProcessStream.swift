import SQLiteData

public enum ProcessStream: String, Sendable, Codable, CaseIterable, Equatable {
  case standardOutput = "stdout"
  case standardError = "stderr"
}

extension ProcessStream: QueryBindable, QueryDecodable {}
