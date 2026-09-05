import Foundation
import Hummingbird
import SQLiteData
import TailregCore
import Testing
import UUIDV7

@testable import TailregMultiplexer

@Suite
struct `MUX capture tests` {
  @Test
  func `Redacts sensitive header values by default and can retain them`() {
    let redacted = CapturedHeaderPolicy.redactSensitiveValues.capture(
      name: "Authorization",
      value: "Bearer secret"
    )
    let retained = CapturedHeaderPolicy.retainAllValues.capture(
      name: "Authorization",
      value: "Bearer secret"
    )

    #expect(redacted == CapturedHTTPHeader(name: "authorization", value: "[REDACTED]"))
    #expect(retained == CapturedHTTPHeader(name: "authorization", value: "Bearer secret"))
  }

  @Test
  func `Keeps a body at the limit and omits one byte over`() {
    var exact = BodyCapture()
    exact.observe(ByteBuffer(repeating: 1, count: BodyCapture.maximumBytes))
    let exactRecord = exact.record(
      exchangeID: UUIDV7(),
      direction: .request,
      contentType: "application/octet-stream"
    )

    var oversized = BodyCapture()
    oversized.observe(ByteBuffer(repeating: 2, count: BodyCapture.maximumBytes))
    oversized.observe(ByteBuffer(repeating: 3, count: 1))
    let oversizedRecord = oversized.record(
      exchangeID: UUIDV7(),
      direction: .response,
      contentType: "application/octet-stream"
    )

    #expect(exactRecord.content?.count == BodyCapture.maximumBytes)
    #expect(exactRecord.omitted == false)
    #expect(oversizedRecord.content == nil)
    #expect(oversizedRecord.observedByteCount == BodyCapture.maximumBytes + 1)
    #expect(oversizedRecord.omitted)
  }

  @Test
  func `Batches a completed exchange and its bodies into storage`() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tailreg-capture-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try openTailregDatabase(
      path: directory.appendingPathComponent("tailreg.sqlite").path,
      kind: .queue
    )
    let muxID = UUIDV7()
    let multiplexer = Multiplexer(
      configuration: Multiplexer.Configuration(id: muxID),
      database: database
    )
    let binding = try await multiplexer.registerRoute(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:3000")!
    )
    let recorder = CaptureRecorder(
      muxID: muxID,
      database: database,
      classificationRefiner: PreviewEchoRefiner(),
      batchSize: 100,
      flushInterval: .milliseconds(5)
    )
    let exchange = HTTPExchangeRecord(
      routeID: binding.id,
      method: "POST",
      path: "/web-0/route/endpoint",
      requestHeaders: [],
      startedAt: Date()
    )
    let classification = HTTPExchangeClassificationRecord(
      exchangeID: exchange.id,
      policyVersion: 1,
      category: .api,
      ruleID: "request.structured-or-mutation",
      tags: [.mutation, .structuredBody],
      requestBodyDisposition: .retain,
      responseBodyDisposition: .retain
    )
    recorder.open(
      exchange,
      classification: classification,
      refinementInput: RequestRefinementInput(
        exchangeID: exchange.id,
        method: "POST",
        path: "/route/endpoint",
        heuristicCategory: .unknown,
        heuristicRuleID: "request.unclassified",
        heuristicTags: [.mutation]
      )
    )
    recorder.responseStarted(
      id: exchange.id,
      at: Date(),
      statusCode: 201,
      headers: [CapturedHTTPHeader(name: "content-type", value: "text/plain")]
    )
    recorder.store(
      HTTPExchangeBodyRecord(
        exchangeID: exchange.id,
        direction: .request,
        contentType: "text/plain",
        content: Data("hello".utf8),
        observedByteCount: 5,
        omitted: false
      )
    )
    recorder.store(
      HTTPExchangeBodyRecord(
        exchangeID: exchange.id,
        direction: .response,
        contentType: "text/plain",
        content: Data("created".utf8),
        observedByteCount: 7,
        omitted: false
      )
    )
    recorder.complete(id: exchange.id, at: Date(), outcome: .complete)
    await recorder.finish()

    let stored = try await database.read { db in
      let exchange = try HTTPExchangeRecord.fetchOne(db)
      return (
        try #require(exchange),
        try HTTPExchangeBodyRecord.fetchAll(db),
        try HTTPExchangeClassificationRecord.fetchOne(db),
        try HTTPExchangeClassificationRefinementRecord.fetchOne(db)
      )
    }
    #expect(stored.0.statusCode == 201)
    #expect(stored.0.requestBodyBytes == 5)
    #expect(stored.0.responseBodyBytes == 7)
    #expect(stored.0.outcome == .complete)
    #expect(stored.1.count == 2)
    #expect(stored.2 == classification)
    #expect(stored.3?.classifierID == "stub")
    #expect(stored.3?.usefulness == .useful)
    #expect(stored.3?.tags == [.mutation, .structuredBody])
    #expect(stored.3?.explanation == "hello")
  }

  @Test
  func `Marks exchanges left open by an earlier MUX as abandoned`() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("tailreg-capture-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try openTailregDatabase(
      path: directory.appendingPathComponent("tailreg.sqlite").path,
      kind: .queue
    )
    let muxID = UUIDV7()
    let multiplexer = Multiplexer(
      configuration: Multiplexer.Configuration(id: muxID),
      database: database
    )
    let route = try await multiplexer.registerRoute(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:3000")!
    )
    let exchange = HTTPExchangeRecord(
      routeID: route.id,
      method: "GET",
      path: "/web-0/stream",
      requestHeaders: [],
      startedAt: Date()
    )
    try await database.write { db in
      try HTTPExchangeRecord.insert { exchange }.execute(db)
    }

    let recorder = CaptureRecorder(
      muxID: muxID,
      database: database,
      batchSize: 100,
      flushInterval: .milliseconds(5)
    )
    await recorder.flush()
    let stored = try await database.read { db in
      try HTTPExchangeRecord.find(exchange.id).fetchOne(db)
    }

    #expect(stored?.outcome == .abandoned)
    #expect(stored?.failure == "mux_restarted")
    #expect(stored?.completedAt != nil)
    await recorder.finish()
  }

  @Test
  func `Restart recovery does not abandon another MUX's exchanges`() async throws {
    let database = try openTailregDatabase(path: ":memory:", kind: .queue)
    let firstMUXID = UUIDV7()
    let secondMUXID = UUIDV7()
    let firstMux = Multiplexer(
      configuration: Multiplexer.Configuration(id: firstMUXID),
      database: database
    )
    let secondMux = Multiplexer(
      configuration: Multiplexer.Configuration(id: secondMUXID),
      database: database
    )
    let firstRoute = try await firstMux.registerRoute(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:3000")!
    )
    let secondRoute = try await secondMux.registerRoute(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:3001")!
    )
    // Both multiplexers run their own restart recovery when they are created, and it abandons
    // whatever is in progress for their MUX. Letting that land before these exchanges exist keeps
    // the test about the recorder under test rather than a race with the multiplexers' own.
    await firstMux.captureRecorder?.flush()
    await secondMux.captureRecorder?.flush()

    let firstExchange = HTTPExchangeRecord(
      routeID: firstRoute.id,
      method: "GET",
      path: "/web-0/stream",
      requestHeaders: [],
      startedAt: Date()
    )
    let secondExchange = HTTPExchangeRecord(
      routeID: secondRoute.id,
      method: "GET",
      path: "/web-0/stream",
      requestHeaders: [],
      startedAt: Date()
    )
    try await database.write { db in
      try HTTPExchangeRecord.insert { [firstExchange, secondExchange] }.execute(db)
    }

    let recorder = CaptureRecorder(
      muxID: firstMUXID,
      database: database,
      batchSize: 100,
      flushInterval: .milliseconds(5)
    )
    await recorder.flush()

    let outcomes = try await database.read { db in
      (
        try HTTPExchangeRecord.find(firstExchange.id).fetchOne(db)?.outcome,
        try HTTPExchangeRecord.find(secondExchange.id).fetchOne(db)?.outcome
      )
    }
    #expect(outcomes.0 == .abandoned)
    #expect(outcomes.1 == .inProgress)
    await recorder.finish()
  }
}

private struct PreviewEchoRefiner: RequestClassificationRefining {
  let classifierID = "stub"
  let classifierVersion = "1"

  func refine(_ input: RequestRefinementInput) async throws -> RequestRefinement {
    RequestRefinement(
      usefulness: .useful,
      category: .api,
      tags: [.mutation, .structuredBody],
      explanation: input.bodyPreview
    )
  }
}
