import AsyncAlgorithms
import Foundation
import SQLiteData
import UUIDV7

public struct ProcessLogMonitor<C: Clock>: Sendable where C.Instant.Duration == Duration {
  private let database: any DatabaseWriter
  private let batchSize: Int
  private let flushInterval: Duration
  private let clock: C

  public init(
    database: any DatabaseWriter,
    batchSize: Int = 200,
    flushInterval: Duration = .milliseconds(250),
    clock: C = ContinuousClock()
  ) {
    self.database = database
    self.batchSize = batchSize
    self.flushInterval = flushInterval
    self.clock = clock
  }

  public func monitor<Output: AsyncSequence & Sendable>(
    _ output: Output,
    for bindingID: UUIDV7,
    onBatch: (@Sendable ([LogLine]) -> Void)? = nil
  ) async throws where Output.Element == LogLine {
    let batches = output.chunks(
      ofCount: batchSize,
      or: AsyncTimerSequence(interval: flushInterval, clock: clock)
    )
    for try await batch in batches {
      try await database.write { db in
        try LogRecord.append(batch, for: bindingID, in: db)
      }
      onBatch?(batch)
    }
  }

  public func monitor(
    standardOutput: FileHandle,
    standardError: FileHandle,
    for bindingID: UUIDV7,
    onBatch: (@Sendable ([LogLine]) -> Void)? = nil
  ) async throws {
    try await monitor(
      merge(
        processOutputLines(standardOutput, as: .standardOutput),
        processOutputLines(standardError, as: .standardError)
      ),
      for: bindingID,
      onBatch: onBatch
    )
  }
}
