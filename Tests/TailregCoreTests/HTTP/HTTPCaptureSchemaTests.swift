import Foundation
import SQLiteData
import Testing
import UUIDV7

@testable import TailregCore

@Suite
struct `HTTP capture schema tests` {
  private func database(_ temp: TempDirectory) throws -> any DatabaseWriter {
    try openTailregDatabase(path: temp.path("tailreg.sqlite"), kind: .queue)
  }

  @Test
  func `Round trips an exchange with duplicate headers and bodies`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let route = MuxRouteRecord(
      name: "web",
      route: "web-0",
      upstreamURL: "http://127.0.0.1:3000",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let exchange = HTTPExchangeRecord(
      routeID: route.id,
      method: "POST",
      host: "node.example.ts.net",
      path: "/web-0/route/endpoint",
      requestHeaders: [
        CapturedHTTPHeader(name: "x-example", value: "first"),
        CapturedHTTPHeader(name: "x-example", value: "second")
      ],
      requestBodyBytes: 5,
      startedAt: Date(timeIntervalSince1970: 1_700_000_001),
      responseStartedAt: Date(timeIntervalSince1970: 1_700_000_002),
      statusCode: 200,
      responseHeaders: [CapturedHTTPHeader(name: "content-type", value: "text/plain")],
      responseBodyBytes: 2,
      completedAt: Date(timeIntervalSince1970: 1_700_000_003),
      outcome: .complete
    )
    let requestBody = HTTPExchangeBodyRecord(
      exchangeID: exchange.id,
      direction: .request,
      contentType: "text/plain",
      content: Data("hello".utf8),
      observedByteCount: 5,
      omitted: false
    )
    let responseBody = HTTPExchangeBodyRecord(
      exchangeID: exchange.id,
      direction: .response,
      contentType: "text/plain",
      content: Data("ok".utf8),
      observedByteCount: 2,
      omitted: false
    )

    try await database.write { db in
      try MuxRouteRecord.insert { route }.execute(db)
      try HTTPExchangeRecord.insert { exchange }.execute(db)
      try HTTPExchangeBodyRecord.insert { [requestBody, responseBody] }.execute(db)
    }

    let stored = try await database.read { db in
      let fetched = try HTTPExchangeRecord.fetchOne(db)
      let exchange = try #require(fetched)
      let bodies =
        try HTTPExchangeBodyRecord
        .order { $0.direction }
        .fetchAll(db)
      return (exchange, bodies)
    }
    #expect(stored.0 == exchange)
    #expect(stored.1 == [requestBody, responseBody])
  }

  @Test
  func `Stores an omitted marker without a partial body`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let route = MuxRouteRecord(
      name: "download",
      route: "download-0",
      upstreamURL: "http://127.0.0.1:3000",
      createdAt: Date()
    )
    let exchange = HTTPExchangeRecord(
      routeID: route.id,
      method: "GET",
      path: "/download-0/archive",
      requestHeaders: [],
      startedAt: Date(),
      completedAt: Date(),
      outcome: .complete
    )
    let body = HTTPExchangeBodyRecord(
      exchangeID: exchange.id,
      direction: .response,
      content: nil,
      observedByteCount: 1_048_577,
      omitted: true
    )

    try await database.write { db in
      try MuxRouteRecord.insert { route }.execute(db)
      try HTTPExchangeRecord.insert { exchange }.execute(db)
      try HTTPExchangeBodyRecord.insert { body }.execute(db)
    }

    let stored = try await database.read { db in
      try HTTPExchangeBodyRecord.fetchOne(db)
    }
    #expect(stored == body)
  }

  @Test
  func `Round trips a classification with multiple and unknown tags`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let route = MuxRouteRecord(
      name: "web",
      route: "web-0",
      upstreamURL: "http://127.0.0.1:3000",
      createdAt: Date()
    )
    let exchange = HTTPExchangeRecord(
      routeID: route.id,
      method: "POST",
      path: "/web-0/action",
      requestHeaders: [],
      startedAt: Date()
    )
    let futureTag = RequestTag(rawValue: Int64(1) << 40)
    let classification = HTTPExchangeClassificationRecord(
      exchangeID: exchange.id,
      policyVersion: 1,
      category: .frameworkData,
      ruleID: "nextjs.server-action",
      tags: [.fetchLike, .mutation, .frameworkAction, .nextJS, futureTag],
      requestBodyDisposition: .retain,
      responseBodyDisposition: .retain
    )

    try await database.write { db in
      try MuxRouteRecord.insert { route }.execute(db)
      try HTTPExchangeRecord.insert { exchange }.execute(db)
      try HTTPExchangeClassificationRecord.insert { classification }.execute(db)
    }

    let stored = try await database.read { db in
      try HTTPExchangeClassificationRecord.fetchOne(db)
    }
    #expect(stored == classification)
    #expect(stored?.tags.contains(all: [.fetchLike, .frameworkAction, .nextJS]) == true)
    #expect(stored?.tags.contains(futureTag) == true)
  }

  @Test
  func `Deleting a route removes its exchanges and bodies`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let route = MuxRouteRecord(
      name: "web",
      route: "web-0",
      upstreamURL: "http://127.0.0.1:3000",
      createdAt: Date()
    )
    let exchange = HTTPExchangeRecord(
      routeID: route.id,
      method: "GET",
      path: "/web-0/",
      requestHeaders: [],
      startedAt: Date()
    )
    let body = HTTPExchangeBodyRecord(
      exchangeID: exchange.id,
      direction: .response,
      content: Data(),
      observedByteCount: 0,
      omitted: false
    )
    let classification = HTTPExchangeClassificationRecord(
      exchangeID: exchange.id,
      policyVersion: 1,
      category: .document,
      ruleID: "browser.navigation",
      tags: [.document],
      requestBodyDisposition: .discard,
      responseBodyDisposition: .provisional
    )

    try await database.write { db in
      try MuxRouteRecord.insert { route }.execute(db)
      try HTTPExchangeRecord.insert { exchange }.execute(db)
      try HTTPExchangeBodyRecord.insert { body }.execute(db)
      try HTTPExchangeClassificationRecord.insert { classification }.execute(db)
      try MuxRouteRecord.where { $0.id.eq(route.id) }.delete().execute(db)
    }

    let counts = try await database.read { db in
      (
        try HTTPExchangeRecord.fetchCount(db),
        try HTTPExchangeBodyRecord.fetchCount(db),
        try HTTPExchangeClassificationRecord.fetchCount(db)
      )
    }
    #expect(counts.0 == 0)
    #expect(counts.1 == 0)
    #expect(counts.2 == 0)
  }

  @Test
  func `Pruning exchanges also removes their bodies`() async throws {
    let temp = try TempDirectory()
    let database = try database(temp)
    let route = MuxRouteRecord(
      name: "web",
      route: "web-0",
      upstreamURL: "http://127.0.0.1:3000",
      createdAt: Date()
    )
    let exchanges = (0..<3)
      .map { index in
        HTTPExchangeRecord(
          routeID: route.id,
          method: "GET",
          path: "/request/\(index)",
          requestHeaders: [],
          startedAt: Date(),
          completedAt: Date(),
          outcome: .complete
        )
      }
    let bodies = exchanges.map { exchange in
      HTTPExchangeBodyRecord(
        exchangeID: exchange.id,
        direction: .response,
        content: Data(),
        observedByteCount: 0,
        omitted: false
      )
    }

    try await database.write { db in
      try MuxRouteRecord.insert { route }.execute(db)
      try HTTPExchangeRecord.insert { exchanges }.execute(db)
      try HTTPExchangeBodyRecord.insert { bodies }.execute(db)
      try HTTPExchangeRecord.prune(for: route.id, keepingLast: 2, in: db)
    }

    let remaining = try await database.read { db in
      (
        try HTTPExchangeRecord.page(for: route.id).fetchAll(db),
        try HTTPExchangeBodyRecord.fetchAll(db)
      )
    }
    #expect(remaining.0.count == 2)
    #expect(remaining.1.count == 2)
  }
}
