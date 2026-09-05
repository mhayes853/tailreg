import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import SQLiteData
import TailregCore
import UUIDV7

public struct MuxIngressResponder: HTTPResponder, Sendable {
  public typealias Context = BasicRequestContext

  private static let refinementHeaderNames: Set<String> = [
    "accept", "content-type", "hx-request", "next-action", "next-router-prefetch",
    "next-router-segment-prefetch", "purpose", "rsc", "sec-fetch-dest", "sec-fetch-mode",
    "sec-fetch-site", "sec-purpose", "x-sveltekit-action"
  ]
  private enum ProxyError: Error {
    case invalidURL
  }

  /// Marks an error as coming from the upstream read side of a proxied body, so a single
  /// `catch` can tell it apart from a failure writing back to the client.
  private struct UpstreamReadFailure: Error {
    let underlying: Error
  }

  private let cookieName: String
  private let publicScheme: PublicScheme
  private let pathPolicy: MuxPathPolicy
  private let unmatchedPathPolicy: UnmatchedPathPolicy
  private let routeResolver: MuxRouteResolver
  private let headerPolicy: MuxHeaderPolicy
  private let captureRecorder: CaptureRecorder

  public init(
    database: any DatabaseWriter,
    muxID: UUIDV7,
    pathPolicy: MuxPathPolicy,
    unmatchedPathPolicy: UnmatchedPathPolicy = .reject,
    cookieName: String,
    publicScheme: PublicScheme,
    capturedHeaderPolicy: CapturedHeaderPolicy = .redactSensitiveValues,
    captureRecorder: CaptureRecorder
  ) {
    self.cookieName = cookieName
    self.publicScheme = publicScheme
    self.pathPolicy = pathPolicy
    self.unmatchedPathPolicy = unmatchedPathPolicy
    self.routeResolver = MuxRouteResolver(
      database: database,
      muxID: muxID,
      pathPolicy: pathPolicy,
      unmatchedPathPolicy: unmatchedPathPolicy,
      cookieName: cookieName
    )
    self.headerPolicy = MuxHeaderPolicy(
      cookieName: cookieName,
      publicScheme: publicScheme,
      capturedHeaderPolicy: capturedHeaderPolicy
    )
    self.captureRecorder = captureRecorder
  }

  public func respond(to request: Request, context: BasicRequestContext) async throws -> Response {
    guard let resolved = try await routeResolver.resolve(request) else {
      return try response(
        MultiplexerErrorResponse(
          error: "route_not_resolved",
          message: "Open a generated Tailreg URL first."
        ),
        status: .notFound,
        for: request,
        context: context
      )
    }

    if headerPolicy.requestHeader("upgrade", in: request) != nil {
      return try response(
        MultiplexerErrorResponse(
          error: "upgrade_not_supported",
          message: "Bidirectional protocol upgrades are not supported by this MUX yet."
        ),
        status: .notImplemented,
        for: request,
        context: context
      )
    }

    if resolved.isExplicit && request.uri.path == "/\(resolved.binding.route)" {
      var location = pathPolicy.publicPath(route: resolved.binding.route)
      if let query = request.uri.query { location += "?\(query)" }
      var headers = HTTPFields()
      headers[.location] = location
      return Response(status: .temporaryRedirect, headers: headers)
    }

    do {
      var response = try await proxy(request, to: resolved)
      if resolved.isExplicit && unmatchedPathPolicy == .lastSelectedRouteCompatibility {
        response.setCookie(
          Cookie(
            name: cookieName,
            value: resolved.binding.route.rawValue,
            path: "/",
            secure: publicScheme == .https,
            httpOnly: true,
            sameSite: .lax
          )
        )
      }
      return response
    } catch {
      context.logger.error(
        "Upstream request failed",
        metadata: ["route": "\(resolved.binding.route)"]
      )
      return try response(
        MultiplexerErrorResponse(error: "upstream_unavailable"),
        status: .badGateway,
        for: request,
        context: context
      )
    }
  }

  private func proxy(_ request: Request, to resolved: ResolvedMuxRoute) async throws -> Response {
    guard resolved.upstreamPath.removingPercentEncoding != nil,
      request.uri.query?.removingPercentEncoding != nil || request.uri.query == nil,
      var components = URLComponents(
        url: resolved.binding.upstream,
        resolvingAgainstBaseURL: false
      )
    else {
      throw ProxyError.invalidURL
    }
    let basePath = components.percentEncodedPath
    let forwardedPath = resolved.upstreamPath
    components.percentEncodedPath = join(basePath: basePath, forwardedPath: forwardedPath)
    components.percentEncodedQuery = request.uri.query

    guard let upstreamURL = components.url else { throw ProxyError.invalidURL }

    var upstreamRequest = HTTPClientRequest(url: upstreamURL.absoluteString)
    upstreamRequest.method = .RAW(value: request.method.rawValue)
    headerPolicy.copyRequestHeaders(
      from: request,
      to: &upstreamRequest,
      forwardedPrefix: pathPolicy.forwardedPrefix(route: resolved.binding.route)
    )

    let exchangeID = UUIDV7()
    upstreamRequest.headers.add(name: "X-Tailreg-Request-ID", value: exchangeID.uuidString)
    openCapture(
      exchangeID: exchangeID,
      request: request,
      resolved: resolved,
      requestHeaders: upstreamRequest.headers.map { header in
        headerPolicy.capturedHeader(name: header.name.lowercased(), value: header.value)
      }
    )

    if request.method != .get && request.method != .head {
      let length: HTTPClientRequest.Body.Length =
        request.headers[.contentLength].flatMap { Int64($0) }.map { .known($0) } ?? .unknown
      upstreamRequest.body = .stream(
        CapturingRequestBodySequence(
          base: request.body,
          capture: RequestBodyCapture(),
          exchangeID: exchangeID,
          contentType: request.headers[.contentType],
          recorder: captureRecorder
        ),
        length: length
      )
    }

    let upstreamResponse: HTTPClientResponse
    do {
      upstreamResponse = try await UpstreamClient.shared.execute(
        upstreamRequest,
        timeout: .hours(24)
      )
    } catch {
      captureRecorder.responseStarted(
        id: exchangeID,
        at: Date(),
        statusCode: Int(HTTPResponse.Status.badGateway.code),
        headers: []
      )
      captureRecorder.complete(
        id: exchangeID,
        at: Date(),
        outcome: .failed,
        failure: "upstream_unavailable"
      )
      throw error
    }
    let headers = headerPolicy.responseHeaders(from: upstreamResponse)
    let status = HTTPResponse.Status(code: Int(upstreamResponse.status.code))
    captureRecorder.responseStarted(
      id: exchangeID,
      at: Date(),
      statusCode: Int(status.code),
      headers: headerPolicy.capturedHeaders(headers)
    )

    return Response(
      status: status,
      headers: headers,
      body: capturedResponseBody(
        upstreamResponse.body,
        contentType: headers[.contentType],
        exchangeID: exchangeID
      )
    )
  }

  private func openCapture(
    exchangeID: UUIDV7,
    request: Request,
    resolved: ResolvedMuxRoute,
    requestHeaders: [CapturedHTTPHeader]
  ) {
    let facts = RequestFacts(
      method: request.method.rawValue,
      path: resolved.upstreamPath,
      query: request.uri.query,
      headers: request.headers
    )
    let classification = RequestClassifier.classify(facts)
    captureRecorder.open(
      HTTPExchangeRecord(
        id: exchangeID,
        routeID: resolved.binding.id,
        method: request.method.rawValue,
        host: request.head.authority,
        path: resolved.isExplicit
          ? pathPolicy.publicPath(
            route: resolved.binding.route,
            remainder: resolved.routeRelativePath
          )
          : request.uri.path,
        query: request.uri.query,
        requestHeaders: requestHeaders,
        startedAt: Date(),
        tailscaleUserLogin: headerPolicy.requestHeader("tailscale-user-login", in: request),
        tailscaleUserName: headerPolicy.requestHeader("tailscale-user-name", in: request)
      ),
      classification: classification.record(exchangeID: exchangeID),
      refinementInput: classification.requestBodyDisposition == .provisional
        || classification.responseBodyDisposition == .provisional
        ? RequestRefinementInput(
          exchangeID: exchangeID,
          method: facts.method,
          path: facts.path,
          queryNames: facts.queryNames.sorted(),
          headers: refinementHeaders(request.headers),
          heuristicCategory: classification.category,
          heuristicRuleID: classification.ruleID,
          heuristicTags: classification.tags
        )
        : nil
    )
  }

  private func capturedResponseBody(
    _ upstreamBody: HTTPClientResponse.Body,
    contentType: String?,
    exchangeID: UUIDV7
  ) -> ResponseBody {
    ResponseBody { writer in
      var capture = BodyCapture()
      var iterator = upstreamBody.makeAsyncIterator()
      do {
        while true {
          let next: ByteBuffer?
          do {
            next = try await iterator.next()
          } catch {
            throw UpstreamReadFailure(underlying: error)
          }
          guard let buffer = next else { break }
          capture.observe(buffer)
          try await writer.write(buffer)
        }
        try await writer.finish(nil)
      } catch let readFailure as UpstreamReadFailure {
        finishCapture(
          capture,
          exchangeID: exchangeID,
          contentType: contentType,
          outcome: .failed,
          failure: "response_stream_failed"
        )
        throw readFailure.underlying
      } catch {
        finishCapture(
          capture,
          exchangeID: exchangeID,
          contentType: contentType,
          outcome: .cancelled,
          failure: "client_disconnected"
        )
        throw error
      }
      finishCapture(
        capture,
        exchangeID: exchangeID,
        contentType: contentType,
        outcome: .complete
      )
    }
  }

  private func finishCapture(
    _ capture: BodyCapture,
    exchangeID: UUIDV7,
    contentType: String?,
    outcome: HTTPExchangeOutcome,
    failure: String? = nil
  ) {
    captureRecorder.store(
      capture.record(
        exchangeID: exchangeID,
        direction: .response,
        contentType: contentType
      )
    )
    captureRecorder.complete(
      id: exchangeID,
      at: Date(),
      outcome: outcome,
      failure: failure
    )
  }

  private func refinementHeaders(_ headers: HTTPFields) -> [CapturedHTTPHeader] {
    headers.compactMap { header in
      let name = header.name.canonicalName
      guard Self.refinementHeaderNames.contains(name) else { return nil }
      return headerPolicy.capturedHeader(name: name, value: header.value)
    }
  }

  private func join(basePath: String, forwardedPath: String) -> String {
    let base =
      basePath == "/" ? "" : basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let forwarded = forwardedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let joined = [base, forwarded].filter { !$0.isEmpty }.joined(separator: "/")
    return "/\(joined)"
  }

  private func response<Body: ResponseEncodable>(
    _ body: Body,
    status: HTTPResponse.Status,
    for request: Request,
    context: BasicRequestContext
  ) throws -> Response {
    var response = try body.response(from: request, context: context)
    response.status = status
    return response
  }
}
