import Foundation
import Hummingbird
import TailregCore
import UUIDV7

struct BodyCapture: Sendable {
  static let maximumBytes = 1_048_576

  private(set) var content = Data()
  private(set) var observedByteCount = 0
  private(set) var omitted = false

  mutating func observe(_ buffer: ByteBuffer) {
    observedByteCount += buffer.readableBytes
    guard !omitted else { return }
    guard observedByteCount <= Self.maximumBytes else {
      content.removeAll(keepingCapacity: false)
      omitted = true
      return
    }
    content.append(contentsOf: buffer.readableBytesView)
  }

  func record(
    exchangeID: UUIDV7,
    direction: HTTPExchangeBodyDirection,
    contentType: String?
  ) -> HTTPExchangeBodyRecord {
    HTTPExchangeBodyRecord(
      exchangeID: exchangeID,
      direction: direction,
      contentType: contentType,
      content: omitted ? nil : content,
      observedByteCount: observedByteCount,
      omitted: omitted
    )
  }
}

actor RequestBodyCapture {
  private var capture = BodyCapture()
  private var finished = false

  func observe(_ buffer: ByteBuffer) {
    capture.observe(buffer)
  }

  func finish(
    exchangeID: UUIDV7,
    contentType: String?,
    recorder: CaptureRecorder
  ) {
    guard !finished else { return }
    finished = true
    recorder.store(
      capture.record(
        exchangeID: exchangeID,
        direction: .request,
        contentType: contentType
      )
    )
  }
}

struct CapturingRequestBodySequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable
where Base.Element == ByteBuffer {
  typealias Element = ByteBuffer

  let base: Base
  let capture: RequestBodyCapture
  let exchangeID: UUIDV7
  let contentType: String?
  let recorder: CaptureRecorder

  struct AsyncIterator: AsyncIteratorProtocol {
    var base: Base.AsyncIterator
    let capture: RequestBodyCapture
    let exchangeID: UUIDV7
    let contentType: String?
    let recorder: CaptureRecorder

    mutating func next() async throws -> ByteBuffer? {
      do {
        guard let buffer = try await base.next() else {
          await capture.finish(
            exchangeID: exchangeID,
            contentType: contentType,
            recorder: recorder
          )
          return nil
        }
        await capture.observe(buffer)
        return buffer
      } catch {
        await capture.finish(
          exchangeID: exchangeID,
          contentType: contentType,
          recorder: recorder
        )
        throw error
      }
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      base: base.makeAsyncIterator(),
      capture: capture,
      exchangeID: exchangeID,
      contentType: contentType,
      recorder: recorder
    )
  }
}
