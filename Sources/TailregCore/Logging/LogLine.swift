import Foundation

public struct LogLine: Sendable, Equatable {
  public let stream: ProcessStream
  public let message: String
  public let at: Date

  public init(stream: ProcessStream, message: String, at: Date) {
    self.stream = stream
    self.message = message
    self.at = at
  }
}
