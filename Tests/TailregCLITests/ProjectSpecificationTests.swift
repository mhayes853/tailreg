import Foundation
import TailregCLI
import TailregCore
import TailregTestSupport
import Testing

@Suite
struct `Project specification tests` {
  @Test
  func `Loads applications and orders dependency levels`() throws {
    let fixture = try TOMLFixture(
      """
      [project]
      name = "storefront"

      [apps.api]
      route = "api"
      port = 8080
      command = ["swift", "run", "API"]

      [apps.web]
      route = "web"
      port = 5173
      command = ["npm", "run", "dev"]
      depends_on = ["api"]

      [apps.worker]
      command = ["swift", "run", "Worker"]
      expose = false
      """
    )

    let specification = try ProjectSpecification.load(from: fixture.file)
    let selected = try specification.selected(["web"])

    #expect(specification.name == "storefront")
    #expect(specification.applications.map(\.name) == ["api", "web", "worker"])
    #expect(selected.map { $0.map(\.name) } == [["api"], ["web"]])
  }

  /// The route in `tailreg.toml` is the one the MUX and the schema have to accept, so a name
  /// they could not serve is reported against the application that wrote it.
  @Test
  func `Rejects a route the MUX could not serve`() throws {
    let fixture = try TOMLFixture(
      """
      [apps.web]
      route = "Café"
      port = 3000
      command = ["web"]
      """
    )

    #expect(throws: ProjectSpecificationError.invalidRoute(application: "web", route: "Café")) {
      try ProjectSpecification.load(from: fixture.file)
    }
  }

  @Test
  func `Rejects duplicate routes`() throws {
    let fixture = try TOMLFixture(
      """
      [apps.api]
      route = "server"
      port = 8080
      command = ["server"]

      [apps.web]
      route = "server"
      port = 3000
      command = ["web"]
      """
    )

    #expect(throws: ProjectSpecificationError.duplicateRoute) {
      try ProjectSpecification.load(from: fixture.file)
    }
  }

  @Test
  func `Rejects dependency cycles`() throws {
    let fixture = try TOMLFixture(
      """
      [apps.first]
      port = 3000
      command = ["first"]
      depends_on = ["second"]

      [apps.second]
      port = 3001
      command = ["second"]
      depends_on = ["first"]
      """
    )

    #expect(throws: ProjectSpecificationError.dependencyCycle) {
      try ProjectSpecification.load(from: fixture.file)
    }
  }

  /// An unexposed application has no route to point anywhere, so it needs no port either.
  @Test
  func `An unexposed application does not need a port`() throws {
    let fixture = try TOMLFixture(
      """
      [apps.worker]
      command = ["swift", "run", "Worker"]
      expose = false
      """
    )

    let specification = try ProjectSpecification.load(from: fixture.file)

    let worker = try #require(specification.applications.first)
    #expect(worker.isExposed == false)
    #expect(worker.exposure == nil)
    #expect(worker.listenerPort == nil)
    #expect(worker.ownership == .managed)
  }

  /// The other half of the same rule: a route has to name an upstream, and a command that never
  /// says where it listens cannot supply one.
  @Test
  func `An exposed command without a port is rejected`() throws {
    let fixture = try TOMLFixture(
      """
      [apps.web]
      route = "web"
      command = ["npm", "run", "dev"]
      """
    )

    #expect(throws: ProjectSpecificationError.missingPort("web")) {
      try ProjectSpecification.load(from: fixture.file)
    }
  }

  @Test
  func `An attached application takes its port from its URL`() throws {
    let fixture = try TOMLFixture(
      """
      [apps.docs]
      route = "docs"
      attach = "http://localhost:4321"
      """
    )

    let docs = try #require(try ProjectSpecification.load(from: fixture.file).applications.first)

    #expect(docs.listenerPort == PortNumber(4321))
    #expect(docs.ownership == .attached)
    #expect(docs.command == nil)
    #expect(docs.exposure?.upstream.description == "http://localhost:4321")
  }

  /// Tailreg proxies to this machine only. Anything else would publish a third party's server on
  /// the user's tailnet.
  @Test
  func `Rejects an attach URL that is not loopback`() throws {
    let fixture = try TOMLFixture(
      """
      [apps.docs]
      route = "docs"
      attach = "http://example.com:8080"
      """
    )

    #expect(throws: ProjectSpecificationError.invalidAttachURL("docs")) {
      try ProjectSpecification.load(from: fixture.file)
    }
  }

  /// The same mistake `up --attach --port` refuses: a port beside an attach URL can only
  /// disagree with it, and would have readiness judged on a port the route never uses.
  @Test
  func `Rejects a port beside an attach URL`() throws {
    let fixture = try TOMLFixture(
      """
      [apps.docs]
      route = "docs"
      port = 4321
      attach = "http://127.0.0.1:8080"
      """
    )

    #expect(throws: ProjectSpecificationError.portWithAttach("docs")) {
      try ProjectSpecification.load(from: fixture.file)
    }
  }
}

/// A `tailreg.toml` in a directory of its own, removed with the fixture.
private final class TOMLFixture {
  let directory: TempDirectory
  let file: URL

  init(_ contents: String) throws {
    directory = try TempDirectory()
    file = URL(fileURLWithPath: try directory.makeFile("tailreg.toml", contents: contents))
  }
}
