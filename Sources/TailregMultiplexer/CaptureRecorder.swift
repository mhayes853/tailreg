import AsyncAlgorithms
import Foundation
import SQLiteData
import TailregCore
import UUIDV7

public final class CaptureRecorder: Sendable {
  private enum Event: Sendable {
    case opened(OpenedEvent)
    case responseStarted(
      id: UUIDV7,
      at: Date,
      statusCode: Int,
      headers: [CapturedHTTPHeader]
    )
    case body(HTTPExchangeBodyRecord)
    case completed(
      id: UUIDV7,
      at: Date,
      outcome: HTTPExchangeOutcome,
      failure: String?
    )
    case abandon(Date)
    case flush(CheckedContinuation<Void, Never>)
  }

  private struct OpenedEvent: Sendable {
    let record: HTTPExchangeRecord
    let classification: HTTPExchangeClassificationRecord?
  }

  private struct ResponseStartedEvent {
    let id: UUIDV7
    let at: Date
    let statusCode: Int
    let headers: [CapturedHTTPHeader]
  }

  private struct CompletedEvent {
    let id: UUIDV7
    let at: Date
    let outcome: HTTPExchangeOutcome
    let failure: String?
  }

  private struct EventBatch {
    var abandonedAt: Date?
    var opened: [OpenedEvent] = []
    var responsesStarted: [ResponseStartedEvent] = []
    var bodies: [HTTPExchangeBodyRecord] = []
    var completed: [CompletedEvent] = []

    init(_ events: [Event]) {
      for event in events {
        switch event {
        case .abandon(let at):
          abandonedAt = at
        case .opened(let event):
          opened.append(event)
        case .responseStarted(let id, let at, let statusCode, let headers):
          responsesStarted.append(
            ResponseStartedEvent(id: id, at: at, statusCode: statusCode, headers: headers)
          )
        case .body(let body):
          bodies.append(body)
        case .completed(let id, let at, let outcome, let failure):
          completed.append(
            CompletedEvent(id: id, at: at, outcome: outcome, failure: failure)
          )
        case .flush:
          break
        }
      }
    }
  }

  private let continuation: AsyncStream<Event>.Continuation
  private let worker: Task<Void, Never>

  public init(
    database: any DatabaseWriter,
    batchSize: Int = 200,
    flushInterval: Duration = .milliseconds(250),
    onError: @escaping @Sendable (any Error) -> Void = { _ in }
  ) {
    let (events, continuation) = AsyncStream.makeStream(of: Event.self)
    self.continuation = continuation
    self.worker = Task {
      let batches = events.chunks(
        ofCount: batchSize,
        or: AsyncTimerSequence(interval: flushInterval, clock: ContinuousClock())
      )
      for await batch in batches {
        do {
          try await database.write { db in
            try Self.apply(batch, in: db)
          }
        } catch {
          onError(error)
        }
        for event in batch {
          if case .flush(let waiter) = event { waiter.resume() }
        }
      }
    }
    continuation.yield(.abandon(Date()))
  }

  public func open(
    _ record: HTTPExchangeRecord,
    classification: HTTPExchangeClassificationRecord? = nil
  ) {
    continuation.yield(.opened(OpenedEvent(record: record, classification: classification)))
  }

  public func responseStarted(
    id: UUIDV7,
    at: Date,
    statusCode: Int,
    headers: [CapturedHTTPHeader]
  ) {
    continuation.yield(
      .responseStarted(id: id, at: at, statusCode: statusCode, headers: headers)
    )
  }

  public func store(_ body: HTTPExchangeBodyRecord) {
    continuation.yield(.body(body))
  }

  public func complete(
    id: UUIDV7,
    at: Date,
    outcome: HTTPExchangeOutcome,
    failure: String? = nil
  ) {
    continuation.yield(.completed(id: id, at: at, outcome: outcome, failure: failure))
  }

  public func flush() async {
    await withCheckedContinuation { waiter in
      continuation.yield(.flush(waiter))
    }
  }

  public func finish() async {
    continuation.finish()
    await worker.value
  }

  private static func apply(_ events: [Event], in db: Database) throws {
    let batch = EventBatch(events)

    if let abandonedAt = batch.abandonedAt {
      try HTTPExchangeRecord
        .where { $0.completedAt.is(nil) }
        .update {
          $0.completedAt = #bind(abandonedAt)
          $0.outcome = #bind(HTTPExchangeOutcome.abandoned)
          $0.failure = #bind("mux_restarted")
        }
        .execute(db)
    }

    if !batch.opened.isEmpty {
      try HTTPExchangeRecord.insert { batch.opened.map(\.record) }.execute(db)
      let classifications = batch.opened.compactMap(\.classification)
      if !classifications.isEmpty {
        try HTTPExchangeClassificationRecord.insert { classifications }.execute(db)
      }
    }

    for response in batch.responsesStarted {
      try HTTPExchangeRecord
        .where { $0.id.eq(response.id) }
        .update {
          $0.responseStartedAt = #bind(response.at)
          $0.statusCode = #bind(response.statusCode)
          $0.responseHeaders = #bind(
            response.headers,
            as: [CapturedHTTPHeader].JSONRepresentation?.self
          )
        }
        .execute(db)
    }

    if !batch.bodies.isEmpty {
      try HTTPExchangeBodyRecord.insert { batch.bodies }.execute(db)
      try updateBodyByteCounts(for: .request, from: batch.bodies, in: db)
      try updateBodyByteCounts(for: .response, from: batch.bodies, in: db)
    }

    for completion in batch.completed {
      try HTTPExchangeRecord
        .where { $0.id.eq(completion.id) }
        .update {
          $0.completedAt = #bind(completion.at)
          $0.outcome = #bind(completion.outcome)
          $0.failure = #bind(completion.failure)
        }
        .execute(db)
    }
  }

  private static func updateBodyByteCounts(
    for direction: HTTPExchangeBodyDirection,
    from bodies: [HTTPExchangeBodyRecord],
    in db: Database
  ) throws {
    let exchangeIDs = bodies.lazy
      .filter { $0.direction == direction }
      .map(\.exchangeID)
    guard !exchangeIDs.isEmpty else { return }

    switch direction {
    case .request:
      try HTTPExchangeRecord
        .where { $0.id.in(exchangeIDs) }
        .update { exchange in
          exchange.requestBodyBytes =
            HTTPExchangeBodyRecord
            .where {
              $0.exchangeID.eq(exchange.id)
                && $0.direction.eq(HTTPExchangeBodyDirection.request)
            }
            .select { $0.observedByteCount }
        }
        .execute(db)
    case .response:
      try HTTPExchangeRecord
        .where { $0.id.in(exchangeIDs) }
        .update { exchange in
          exchange.responseBodyBytes =
            HTTPExchangeBodyRecord
            .where {
              $0.exchangeID.eq(exchange.id)
                && $0.direction.eq(HTTPExchangeBodyDirection.response)
            }
            .select { $0.observedByteCount }
        }
        .execute(db)
    }
  }
}
