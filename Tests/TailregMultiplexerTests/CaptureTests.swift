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
    let registry = BindingRegistry(database: database)
    let binding = try await registry.register(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:3000")!
    )
    let recorder = CaptureRecorder(
      database: database,
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
    recorder.open(exchange)
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
    await recorder.flush()

    let stored = try await database.read { db in
      let exchange = try HTTPExchangeRecord.fetchOne(db)
      return (
        try #require(exchange),
        try HTTPExchangeBodyRecord.fetchAll(db)
      )
    }
    #expect(stored.0.statusCode == 201)
    #expect(stored.0.requestBodyBytes == 5)
    #expect(stored.0.responseBodyBytes == 7)
    #expect(stored.0.outcome == .complete)
    #expect(stored.1.count == 2)

    await recorder.finish()
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
    let route = MuxRouteRecord(
      name: "web",
      route: "web-0",
      upstreamURL: "http://127.0.0.1:3000",
      createdAt: Date()
    )
    let exchange = HTTPExchangeRecord(
      routeID: route.id,
      method: "GET",
      path: "/web-0/stream",
      requestHeaders: [],
      startedAt: Date()
    )
    try await database.write { db in
      try MuxRouteRecord.insert { route }.execute(db)
      try HTTPExchangeRecord.insert { exchange }.execute(db)
    }

    let recorder = CaptureRecorder(
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
}
