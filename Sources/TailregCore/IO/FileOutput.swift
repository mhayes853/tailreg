import Foundation

/// Follows lines appended to a regular file from its current end.
///
/// The handle is intentionally kept open: if the file is renamed while the process continues to
/// write its original descriptor, the monitor keeps following that original file. If the file is
/// truncated in place, reading resumes from offset zero.
public func fileOutputLines(
  _ file: ProcessOutputFile,
  as stream: ProcessStream,
  pollInterval: Duration = .milliseconds(250),
  lineLimit: Int = 64 * 1024,
  now: @escaping @Sendable () -> Date = Date.init
) -> AsyncStream<LogLine> {
  let (output, continuation) = AsyncStream.makeStream(of: LogLine.self)

  let task = Task {
    do {
      let handle = try FileHandle(forReadingFrom: file.url)
      defer { try? handle.close() }

      var offset = try handle.seekToEnd()
      var framer = LineFramer(limit: lineLimit)

      while !Task.isCancelled {
        let end = try handle.seekToEnd()
        if end < offset { offset = 0 }

        if end > offset {
          try handle.seek(toOffset: offset)
          let data = try handle.readToEnd() ?? Data()
          offset += UInt64(data.count)
          for message in framer.consume(data) {
            continuation.yield(LogLine(stream: stream, message: message, at: now()))
          }
        }

        try await Task.sleep(for: pollInterval)
      }

      if let tail = framer.finish() {
        continuation.yield(LogLine(stream: stream, message: tail, at: now()))
      }
      continuation.finish()
    } catch {
      continuation.finish()
    }
  }

  continuation.onTermination = { _ in task.cancel() }
  return output
}
