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
    let refinementInput: RequestRefinementInput?
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
  private let refinementContinuation: AsyncStream<RequestRefinementInput>.Continuation?
  private let refinementWorker: Task<Void, Never>?

  public init(
    database: any DatabaseWriter,
    classificationRefiner: (any RequestClassificationRefining)? = nil,
    batchSize: Int = 200,
    flushInterval: Duration = .milliseconds(250),
    onError: @escaping @Sendable (any Error) -> Void = { _ in }
  ) {
    let refinementPipeline = classificationRefiner.map { refiner in
      let (inputs, continuation) = AsyncStream.makeStream(of: RequestRefinementInput.self)
      let worker = Task {
        for await input in inputs {
          let startedAt = ContinuousClock.now
          let record: HTTPExchangeClassificationRefinementRecord
          do {
            record = Self.refinementRecord(
              input: input,
              refiner: refiner,
              refinement: try await refiner.refine(input),
              duration: startedAt.duration(to: .now)
            )
          } catch {
            onError(error)
            record = Self.refinementRecord(
              input: input,
              refiner: refiner,
              failure: error,
              duration: startedAt.duration(to: .now)
            )
          }
          do {
            try await database.write { db in
              try HTTPExchangeClassificationRefinementRecord.insert { record }.execute(db)
            }
          } catch {
            onError(error)
          }
        }
      }
      return (continuation, worker)
    }
    self.refinementContinuation = refinementPipeline?.0
    self.refinementWorker = refinementPipeline?.1

    let (events, continuation) = AsyncStream.makeStream(of: Event.self)
    self.continuation = continuation
    self.worker = Task {
      var pendingRefinements: [UUIDV7: RequestRefinementInput] = [:]
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
          switch event {
          case .opened(let opened):
            if refinementPipeline != nil, let input = opened.refinementInput {
              pendingRefinements[opened.record.id] = input
            }
          case .body(let body):
            guard body.direction == .request, var input = pendingRefinements[body.exchangeID]
            else { continue }
            input.bodyByteCount = body.observedByteCount
            input.bodyPreview = Self.bodyPreview(body)
            pendingRefinements[body.exchangeID] = input
          case .completed(let id, _, _, _):
            guard let input = pendingRefinements.removeValue(forKey: id) else { continue }
            refinementPipeline?.0.yield(input)
          case .abandon:
            pendingRefinements.removeAll()
          case .flush(let waiter):
            waiter.resume()
          case .responseStarted:
            break
          }
        }
      }
    }
    continuation.yield(.abandon(Date()))
  }

  public func open(
    _ record: HTTPExchangeRecord,
    classification: HTTPExchangeClassificationRecord? = nil,
    refinementInput: RequestRefinementInput? = nil
  ) {
    let event = OpenedEvent(
      record: record,
      classification: classification,
      refinementInput: refinementInput
    )
    continuation.yield(.opened(event))
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
    refinementContinuation?.finish()
    await refinementWorker?.value
  }

  private static func refinementRecord(
    input: RequestRefinementInput,
    refiner: any RequestClassificationRefining,
    refinement: RequestRefinement? = nil,
    failure: (any Error)? = nil,
    duration: Duration
  ) -> HTTPExchangeClassificationRefinementRecord {
    HTTPExchangeClassificationRefinementRecord(
      exchangeID: input.exchangeID,
      classifierID: refiner.classifierID,
      classifierVersion: refiner.classifierVersion,
      usefulness: refinement?.usefulness,
      category: refinement?.category,
      tags: refinement?.tags ?? [],
      durationMilliseconds: max(0, Int(duration / .milliseconds(1))),
      explanation: refinement?.explanation,
      failure: failure.map { String(String(describing: $0).prefix(1_000)) }
    )
  }

  private static func bodyPreview(_ body: HTTPExchangeBodyRecord) -> String? {
    guard let content = body.content, let type = body.contentType?.lowercased(),
      ["text/", "json", "xml", "graphql", "x-www-form-urlencoded"]
        .contains(where: type.contains)
    else { return nil }
    return String(decoding: content.prefix(4_096), as: UTF8.self)
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
