import Foundation
import SQLiteData
import TailregCore
import TailregMultiplexer
import Testing
import UUIDV7

@Suite
struct `MUX route persistence tests` {
  private func database() throws -> any DatabaseWriter {
    try openTailregDatabase(path: ":memory:", kind: .queue)
  }

  private func multiplexer(
    database: any DatabaseWriter,
    muxID: UUIDV7 = UUIDV7(),
    externalPathPrefix: String = ""
  ) throws -> Multiplexer {
    let pathPolicy =
      externalPathPrefix.isEmpty
      ? MuxPathPolicy()
      : try MuxPathPolicy(externalPathPrefix: externalPathPrefix)
    return Multiplexer(
      configuration: Multiplexer.Configuration(id: muxID, pathPolicy: pathPolicy),
      database: database
    )
  }

  @Test
  func `Duplicate names receive stable incrementing routes`() async throws {
    let mux = try multiplexer(database: database())

    let first = try await mux.registerRoute(
      name: "Web",
      upstream: URL(string: "http://127.0.0.1:3000")!
    )
    let second = try await mux.registerRoute(
      name: "Web",
      upstream: URL(string: "http://127.0.0.1:3001")!
    )

    #expect(first.route == "web-0")
    #expect(second.route == "web-1")
    #expect(first.publicPath == "/web-0/")
    #expect(try await mux.routes().count == 2)
  }

  @Test
  func `External prefix is included in public paths`() async throws {
    let mux = try multiplexer(database: database(), externalPathPrefix: "/alpha")
    let binding = try await mux.registerRoute(
      name: "Web",
      upstream: URL(string: "http://127.0.0.1:3000")!
    )

    #expect(binding.publicPath == "/alpha/web-0/")
  }

  @Test
  func `Names are converted to URL-safe route segments`() async throws {
    let mux = try multiplexer(database: database())
    let binding = try await mux.registerRoute(
      name: "My Web_App!",
      upstream: URL(string: "https://localhost:3000/base")!
    )

    #expect(binding.route == "my-web-app-0")
  }

  @Test
  func `Unregistering removes the route from persistence`() async throws {
    let database = try database()
    let muxID = UUIDV7()
    let mux = try multiplexer(database: database, muxID: muxID)
    let binding = try await mux.registerRoute(
      name: "web",
      upstream: URL(string: "http://localhost:3000")!
    )

    #expect(try await mux.unregisterRoute(route: binding.route) == binding)
    #expect(try await mux.binding(route: binding.route) == nil)

    let reloaded = try multiplexer(database: database, muxID: muxID)
    #expect(try await reloaded.routes().isEmpty)
  }

  @Test
  func `Invalid routes are rejected`() async throws {
    let mux = try multiplexer(database: database())

    await #expect(throws: MuxRouteError.invalidName) {
      try await mux.registerRoute(name: "---", upstream: URL(string: "http://localhost:3000")!)
    }
    await #expect(throws: MuxRouteError.invalidUpstream) {
      try await mux.registerRoute(name: "web", upstream: URL(fileURLWithPath: "/tmp/socket"))
    }
  }

  @Test
  func `A MUX observes routes committed through another instance`() async throws {
    let database = try database()
    let muxID = UUIDV7()
    let firstMux = try multiplexer(database: database, muxID: muxID)
    let observingMux = try multiplexer(database: database, muxID: muxID)
    let first = try await firstMux.registerRoute(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:3000")!
    )

    let restored = try #require(try await observingMux.binding(route: first.route))

    #expect(restored.id == first.id)
    #expect(restored.upstream == first.upstream)
    #expect(restored.pathMode == first.pathMode)
  }

  @Test
  func `A persisted MUX rejects a different external prefix`() async throws {
    let database = try database()
    let muxID = UUIDV7()
    try await multiplexer(
      database: database,
      muxID: muxID,
      externalPathPrefix: "/alpha"
    )
    .prepare()

    let changed = try multiplexer(
      database: database,
      muxID: muxID,
      externalPathPrefix: "/beta"
    )
    await #expect(
      throws: MuxRouteError.externalPathPrefixMismatch(
        expected: "/alpha",
        actual: "/beta"
      )
    ) {
      try await changed.prepare()
    }
  }

  @Test
  func `Different MUX instances can use the same route`() async throws {
    let database = try database()
    let first = try multiplexer(database: database)
    let second = try multiplexer(database: database)

    let firstRoute = try await first.registerRoute(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:3000")!
    )
    let secondRoute = try await second.registerRoute(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:3001")!
    )

    #expect(firstRoute.route == "web-0")
    #expect(secondRoute.route == "web-0")
    #expect(firstRoute.muxID != secondRoute.muxID)
  }

  @Test
  func `Updating a route changes its upstream and path mode durably`() async throws {
    let database = try database()
    let muxID = UUIDV7()
    let mux = try multiplexer(database: database, muxID: muxID)
    let original = try await mux.registerRoute(
      name: "web",
      upstream: URL(string: "http://127.0.0.1:3000")!
    )
    let updated = try await mux.updateRoute(
      route: original.route,
      upstream: URL(string: "http://127.0.0.1:4000")!,
      pathMode: .preserveRoutePrefix
    )

    let reloaded = try multiplexer(database: database, muxID: muxID)
    let restored = try #require(try await reloaded.binding(route: original.route))
    #expect(updated.upstream.port == 4000)
    #expect(restored.upstream.port == 4000)
    #expect(restored.pathMode == .preserveRoutePrefix)
  }
}
