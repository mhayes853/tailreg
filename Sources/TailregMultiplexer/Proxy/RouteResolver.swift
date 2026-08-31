import Hummingbird

struct ResolvedMuxRoute: Sendable {
  let binding: MultiplexerBinding
  let upstreamPath: String
  let isExplicit: Bool
}

struct MuxRouteResolver: Sendable {
  private let registry: BindingRegistry
  private let cookieName: String

  init(registry: BindingRegistry, cookieName: String) {
    self.registry = registry
    self.cookieName = cookieName
  }

  func resolve(_ request: Request) async -> ResolvedMuxRoute? {
    let path = request.uri.path
    if let route = firstSegment(path), let binding = await registry.binding(route: route) {
      let remainder = path.dropFirst(route.count + 1)
      return ResolvedMuxRoute(
        binding: binding,
        upstreamPath: remainder.isEmpty ? "/" : String(remainder),
        isExplicit: true
      )
    }

    if let token = request.cookies[cookieName]?.value,
      let binding = await registry.binding(token: token)
    {
      return ResolvedMuxRoute(binding: binding, upstreamPath: path, isExplicit: false)
    }

    return nil
  }

  private func firstSegment(_ path: String) -> String? {
    path.split(separator: "/", omittingEmptySubsequences: true).first.map { String($0) }
  }
}
