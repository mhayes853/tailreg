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

  /// Monitors the independently readable destinations discovered from an already-running
  /// process. Terminal, pipe, socket, and inaccessible destinations are intentionally ignored:
  /// attempting to read them cannot observe output safely.
  public func monitor(
    _ output: ProcessOutput,
    for bindingID: UUIDV7,
    onBatch: (@Sendable ([LogLine]) -> Void)? = nil
  ) async throws {
    let standardOutput = output.file(for: .standardOutput)
    let standardError = output.file(for: .standardError)

    switch (standardOutput, standardError) {
    case (nil, nil):
      return
    case let (.some(file), nil):
      try await monitor(fileOutputLines(file, as: .standardOutput), for: bindingID, onBatch: onBatch)
    case let (nil, .some(file)):
      try await monitor(fileOutputLines(file, as: .standardError), for: bindingID, onBatch: onBatch)
    case let (.some(stdout), .some(stderr)) where stdout.identity == stderr.identity:
      // `2>&1` has already discarded the source distinction. Follow it once to avoid duplicate
      // records; stdout is the conventional label for that merged destination.
      try await monitor(fileOutputLines(stdout, as: .standardOutput), for: bindingID, onBatch: onBatch)
    case let (.some(stdout), .some(stderr)):
      try await monitor(
        merge(
          fileOutputLines(stdout, as: .standardOutput),
          fileOutputLines(stderr, as: .standardError)
        ),
        for: bindingID,
        onBatch: onBatch
      )
    }
  }
}

private extension ProcessOutput {
  func file(for stream: ProcessStream) -> ProcessOutputFile? {
    let target = stream == .standardOutput ? standardOutput : standardError
    guard case let .regularFile(file) = target else { return nil }
    return file
  }
}
