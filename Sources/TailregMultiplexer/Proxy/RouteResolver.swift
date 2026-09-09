import Hummingbird
import SQLiteData
import TailregCore
import UUIDV7

/// What the MUX does with a request whose first path segment names no live route.
public enum UnmatchedPathPolicy: Equatable, Sendable {
  case reject
  case lastSelectedRouteCompatibility
}

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
      // Everything after the first segment, however many slashes led into it: `//web/x` has to
      // forward `/x` rather than a remainder measured from a single assumed slash.
      let remainder = path.drop(while: { $0 == "/" }).dropFirst(route.rawValue.count)
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
    if let route = request.cookies[cookieName].flatMap({ MuxRouteName(rawValue: $0.value) }),
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

  /// The first path segment, when it could name a route at all.
  ///
  /// A segment that is not a route name cannot match one, so it never reaches the database.
  private func firstSegment(_ path: String) -> MuxRouteName? {
    path.split(separator: "/", omittingEmptySubsequences: true).first
      .flatMap { MuxRouteName(rawValue: String($0)) }
  }

  private func binding(route: MuxRouteName) async throws -> MultiplexerBinding? {
    try await database.read { database in
      return try MuxRouteQueries.live(muxID: muxID, route: route, in: database)
        .map { try MultiplexerBinding(record: $0, pathPolicy: pathPolicy) }
    }
  }
}
