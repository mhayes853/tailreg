import TailregCore
import TailregMultiplexer
import Testing

@Suite
struct `MUX path policy tests` {
  @Test
  func `Builds public and forwarded paths beneath an external prefix`() throws {
    let policy = try MuxPathPolicy(externalPathPrefix: "/alpha")

    #expect(policy.publicPath(route: "web") == "/alpha/web/")
    #expect(policy.publicPath(route: "web", remainder: "/users") == "/alpha/web/users")
    #expect(policy.forwardedPrefix(route: "web") == "/alpha/web")
  }

  @Test
  func `Transforms upstream paths according to the route mode`() throws {
    let policy = try MuxPathPolicy(externalPathPrefix: "/alpha")

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

  @Test
  func `Normalizes root and rejects malformed external prefixes`() throws {
    #expect(try MuxPathPolicy(externalPathPrefix: "/").externalPathPrefix == "")
    #expect(throws: MuxPathPolicyError.invalidExternalPathPrefix) {
      try MuxPathPolicy(externalPathPrefix: "alpha")
    }
    #expect(throws: MuxPathPolicyError.invalidExternalPathPrefix) {
      try MuxPathPolicy(externalPathPrefix: "/alpha/")
    }
  }
}
