import TailregCore
import TailregMultiplexer
import Testing

@Suite
struct `MUX path policy tests` {
  @Test
  func `Builds public and forwarded paths from the root`() throws {
    let policy = MuxPathPolicy()

    #expect(policy.publicPath(route: "web") == "/web/")
    #expect(policy.publicPath(route: "web", remainder: "/users") == "/web/users")
    #expect(policy.forwardedPrefix(route: "web") == "/web")
  }

  @Test
  func `Transforms upstream paths according to the route mode`() throws {
    let policy = MuxPathPolicy()

    #expect(
      policy.upstreamPath(route: "web", remainder: "/users", mode: .stripRoutePrefix)
        == "/users"
    )
    #expect(
      policy.upstreamPath(route: "web", remainder: "/users", mode: .preserveRoutePrefix)
        == "/web/users"
    )
    #expect(
      policy.upstreamPath(route: "web", remainder: "/docs/", mode: .preserveRoutePrefix)
        == "/web/docs/"
    )
  }

}
