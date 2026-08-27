import Dispatch
import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

private final class ProcessOutputState: @unchecked Sendable {
  var framer: LineFramer
  var dropped = 0

  init(lineLimit: Int) {
    self.framer = LineFramer(limit: lineLimit)
  }
}

public func processOutputLines(
  _ handle: FileHandle,
  as stream: ProcessStream,
  bufferLimit: Int = 10_000,
  lineLimit: Int = 64 * 1024,
  readSize: Int = 16 * 1024,
  now: @escaping @Sendable () -> Date = Date.init
) -> AsyncStream<LogLine> {
  let (output, continuation) = AsyncStream.makeStream(
    of: LogLine.self,
    bufferingPolicy: .bufferingNewest(bufferLimit)
  )

  let descriptor = handle.fileDescriptor
  _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

  let state = ProcessOutputState(lineLimit: lineLimit)
  nonisolated(unsafe) let source = DispatchSource.makeReadSource(
    fileDescriptor: descriptor,
    queue: DispatchQueue(label: "com.tailreg.io.processoutput.\(stream.rawValue)")
  )

  @Sendable func emit(_ message: String) {
    if state.dropped > 0 {
      let notice = LogLine(
        stream: .standardError,
        message: "[tailreg] dropped \(state.dropped) lines",
        at: now()
      )
      if case .enqueued = continuation.yield(notice) {
        state.dropped = 0
      }
    }
    let line = LogLine(stream: stream, message: message, at: now())
    if case .dropped = continuation.yield(line) {
      state.dropped += 1
    }
  }

  source.setEventHandler {
    var buffer = [UInt8](repeating: 0, count: readSize)
    while true {
      let count = buffer.withUnsafeMutableBytes {
        read(descriptor, $0.baseAddress, $0.count)
      }
      if count > 0 {
        for message in state.framer.consume(Data(buffer[0..<count])) {
          emit(message)
        }
        continue
      }
      if count == 0 {
        source.cancel()
        return
      }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { return }
      source.cancel()
      return
    }
  }

  source.setCancelHandler {
    if let tail = state.framer.finish() {
      emit(tail)
    }
    continuation.finish()
    try? handle.close()
  }

  continuation.onTermination = { _ in source.cancel() }
  source.resume()

  return output
}
