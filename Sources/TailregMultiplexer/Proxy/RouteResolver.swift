import Hummingbird
import SQLiteData
import UUIDV7

struct ResolvedMuxRoute: Sendable {
  let binding: MultiplexerBinding
  let upstreamPath: String
  let routeRelativePath: String
  let isExplicit: Bool
}

struct MuxRouteResolver: Sendable {
  private let database: any DatabaseWriter
  private let muxID: UUIDV7
  private let pathPolicy: MuxPathPolicy
  private let unmatchedPathPolicy: UnmatchedPathPolicy
  private let cookieName: String

  init(
    database: any DatabaseWriter,
    muxID: UUIDV7,
    pathPolicy: MuxPathPolicy,
    unmatchedPathPolicy: UnmatchedPathPolicy,
    cookieName: String
  ) {
    self.database = database
    self.muxID = muxID
    self.pathPolicy = pathPolicy
    self.unmatchedPathPolicy = unmatchedPathPolicy
    self.cookieName = cookieName
  }

  func resolve(_ request: Request) async throws -> ResolvedMuxRoute? {
    let path = request.uri.path
    if let route = firstSegment(path), let binding = try await binding(route: route) {
      let remainder = path.dropFirst(route.count + 1)
      let relativePath = remainder.isEmpty ? "/" : String(remainder)
      return ResolvedMuxRoute(
        binding: binding,
        upstreamPath: pathPolicy.upstreamPath(
          route: binding.route,
          remainder: relativePath,
          mode: binding.pathMode
        ),
        routeRelativePath: relativePath,
        isExplicit: true
      )
    }

    guard unmatchedPathPolicy == .lastSelectedRouteCompatibility else { return nil }
    if let route = request.cookies[cookieName]?.value,
      let binding = try await binding(route: route)
    {
      return ResolvedMuxRoute(
        binding: binding,
        upstreamPath: path,
        routeRelativePath: path,
        isExplicit: false
      )
    }

    return nil
  }

  private func firstSegment(_ path: String) -> String? {
    path.split(separator: "/", omittingEmptySubsequences: true).first.map { String($0) }
  }

  private func binding(route: String) async throws -> MultiplexerBinding? {
    try await database.read { database in
      return try MuxRouteQueries.live(muxID: muxID, route: route, in: database)
        .map { try MultiplexerBinding(record: $0, pathPolicy: pathPolicy) }
    }
  }
}
