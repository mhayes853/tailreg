import Foundation
import SQLiteData
import TailregTestSupport
import Testing
import UUIDV7

@testable import TailregCore

@Suite
struct `MUX route name tests` {
  /// Names the column's CHECK constraint also rejects, so the type and the schema agree on them.
  ///
  /// `web-` and a 65 character name are deliberately not here: the column accepts both, and the
  /// type is the stricter of the two.
  private static let namesTheColumnRejects = ["", "Web", "café", "٣", "-web", "web app", "web_app"]

  private static let validNames = ["web", "web-0", "a", String(repeating: "a", count: 64)]

  @Test(arguments: validNames)
  func `Accepts a route that can address a MUX route`(name: String) {
    #expect(MuxRouteName(rawValue: name)?.rawValue == name)
  }

  @Test(
    arguments: namesTheColumnRejects + ["web-", String(repeating: "a", count: 65)]
  )
  func `Rejects a route that could never be served`(name: String) {
    #expect(MuxRouteName(rawValue: name) == nil)
  }

  /// The point of the type: a route the CLI accepts has to be one the schema can hold, or the
  /// failure surfaces as a constraint violation deep inside registration.
  @Test(arguments: validNames)
  func `A route the type accepts satisfies the column constraint`(name: String) async throws {
    let database = try TestDatabase.inMemory()

    try await insert(route: name, into: database)

    let stored = try await database.read { db in try MuxRouteRecord.fetchOne(db) }
    #expect(stored?.route == MuxRouteName(rawValue: name))
  }

  @Test(arguments: namesTheColumnRejects)
  func `The column rejects the routes the type rejects`(name: String) async throws {
    let database = try TestDatabase.inMemory()

    let reported = await #expect(throws: DatabaseError.self) {
      try await insert(route: name, into: database)
    }

    #expect(reported?.resultCode == .SQLITE_CONSTRAINT)
  }

  @Test
  func `Is coded as a bare string and decoding rejects an impossible one`() throws {
    let route = try #require(MuxRouteName(rawValue: "web-0"))

    let encoded = try JSONEncoder().encode(["route": route])
    #expect(String(decoding: encoded, as: UTF8.self) == #"{"route":"web-0"}"#)
    #expect(
      try JSONDecoder().decode([String: MuxRouteName].self, from: encoded) == ["route": route]
    )
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode([String: MuxRouteName].self, from: Data(#"{"route":"Web"}"#.utf8))
    }
  }

  /// Written as raw SQL because the record cannot carry an invalid route any more, and the
  /// constraint is what this is about.
  private func insert(route: String, into database: any DatabaseWriter) async throws {
    let mux = MuxInstanceRecord()
    try await database.write { db in
      try MuxInstanceRecord.insert { mux }.execute(db)
      try #sql(
        """
        INSERT INTO "muxRoutes"
          ("id", "muxID", "name", "route", "upstreamURL", "pathMode", "createdAt")
          VALUES (\(bind: UUIDV7()), \(bind: mux.id), 'web', \(bind: route),
                  'http://127.0.0.1:3000', 'strip-route-prefix', \(bind: Date()))
        """
      )
      .execute(db)
    }
  }
}
