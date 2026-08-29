import Foundation
import TailregMultiplexer
import Testing

@Suite
struct `Binding registry tests` {
  @Test
  func `Duplicate names receive stable incrementing routes`() async throws {
    let registry = BindingRegistry()

    let first = try await registry.register(
      name: "Web",
      upstream: URL(string: "http://127.0.0.1:3000")!
    )
    let second = try await registry.register(
      name: "Web",
      upstream: URL(string: "http://127.0.0.1:3001")!
    )

    #expect(first.route == "web-0")
    #expect(second.route == "web-1")
    #expect(first.publicPath == "/web-0/")
    #expect(await registry.count() == 2)
  }

  @Test
  func `Names are converted to URL-safe route segments`() async throws {
    let registry = BindingRegistry()
    let binding = try await registry.register(
      name: "My Web_App!",
      upstream: URL(string: "https://localhost:3000/base")!
    )

    #expect(binding.route == "my-web-app-0")
  }

  @Test
  func `Issued tokens resolve without exposing a route name`() async throws {
    let registry = BindingRegistry()
    let binding = try await registry.register(
      name: "api",
      upstream: URL(string: "http://localhost:8080")!
    )
    let token = try #require(await registry.issueToken(for: binding.route))

    #expect(await registry.binding(token: token) == binding)
    #expect(await registry.issueToken(for: binding.route) == token)
    #expect(await registry.binding(token: "invalid") == nil)
  }

  @Test
  func `Unregistering removes the binding and its routing contexts`() async throws {
    let registry = BindingRegistry()
    let binding = try await registry.register(
      name: "web",
      upstream: URL(string: "http://localhost:3000")!
    )
    let token = try #require(await registry.issueToken(for: binding.route))

    #expect(await registry.unregister(route: binding.route) == binding)
    #expect(await registry.binding(route: binding.route) == nil)
    #expect(await registry.binding(token: token) == nil)
    #expect(await registry.bindings().isEmpty)
  }

  @Test
  func `Invalid bindings are rejected`() async throws {
    let registry = BindingRegistry()

    await #expect(throws: BindingRegistryError.invalidName) {
      try await registry.register(name: "---", upstream: URL(string: "http://localhost:3000")!)
    }
    await #expect(throws: BindingRegistryError.invalidUpstream) {
      try await registry.register(name: "web", upstream: URL(fileURLWithPath: "/tmp/socket"))
    }
  }
}
