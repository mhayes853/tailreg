import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import TailregCore
import UUIDV7

public struct MuxIngressResponder: HTTPResponder, Sendable {
  public typealias Context = BasicRequestContext

  private typealias ResolvedRoute = (
    binding: MultiplexerBinding,
    upstreamPath: String,
    isExplicit: Bool
  )

  private static let hopByHopHeaders: Set<String> = [
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "transfer-encoding", "upgrade"
  ]
  private enum ProxyError: Error {
    case invalidURL
  }

  private let registry: BindingRegistry
  private let cookieName: String
  private let secureCookies: Bool
  private let capturedHeaderPolicy: CapturedHeaderPolicy
  private let captureRecorder: CaptureRecorder?

  public init(
    registry: BindingRegistry,
    cookieName: String,
    secureCookies: Bool,
    capturedHeaderPolicy: CapturedHeaderPolicy = .redactSensitiveValues,
    captureRecorder: CaptureRecorder? = nil
  ) {
    self.registry = registry
    self.cookieName = cookieName
    self.secureCookies = secureCookies
    self.capturedHeaderPolicy = capturedHeaderPolicy
    self.captureRecorder = captureRecorder
  }

  public func respond(to request: Request, context: BasicRequestContext) async throws -> Response {
    if request.uri.path == "/_tailreg/status" {
      return try response(
        MultiplexerStatus(status: "ok"),
        status: .ok,
        for: request,
        context: context
      )
    }
    guard let resolved = await resolve(request) else {
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

    if resolved.isExplicit && request.uri.path == "/\(resolved.binding.route)" {
      var location = "/\(resolved.binding.route)/"
      if let query = request.uri.query { location += "?\(query)" }
      var headers = HTTPFields()
      headers[.location] = location
      return Response(status: .temporaryRedirect, headers: headers)
    }

    do {
      var response = try await proxy(request, to: resolved)
      if resolved.isExplicit {
        response.setCookie(
          Cookie(
            name: cookieName,
            value: resolved.binding.token,
            path: "/",
            secure: secureCookies,
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

  private func proxy(_ request: Request, to resolved: ResolvedRoute) async throws -> Response {
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
    copyRequestHeaders(from: request, to: &upstreamRequest, route: resolved.binding.route)

    let exchangeID = captureRecorder.map { _ in UUIDV7() }
    if let captureRecorder, let exchangeID {
      upstreamRequest.headers.add(name: "X-Tailreg-Request-ID", value: exchangeID.uuidString)
      captureRecorder.open(
        HTTPExchangeRecord(
          id: exchangeID,
          routeID: resolved.binding.id,
          method: request.method.rawValue,
          host: request.head.authority,
          path: request.uri.path,
          query: request.uri.query,
          requestHeaders: upstreamRequest.headers.map { header in
            capturedHeader(name: header.name.lowercased(), value: header.value)
          },
          startedAt: Date(),
          tailscaleUserLogin: requestHeader("tailscale-user-login", in: request),
          tailscaleUserName: requestHeader("tailscale-user-name", in: request)
        )
      )
    }

    if request.method != .get && request.method != .head {
      let length: HTTPClientRequest.Body.Length =
        request.headers[.contentLength].flatMap { Int64($0) }.map { .known($0) } ?? .unknown
      if let captureRecorder, let exchangeID {
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
      } else {
        upstreamRequest.body = .stream(request.body, length: length)
      }
    }

    let upstreamResponse: HTTPClientResponse
    do {
      upstreamResponse = try await HTTPClient.shared.execute(
        upstreamRequest,
        timeout: .hours(24)
      )
    } catch {
      if let captureRecorder, let exchangeID {
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
      }
      throw error
    }
    let headers = responseHeaders(from: upstreamResponse)
    let status = HTTPResponse.Status(code: Int(upstreamResponse.status.code))
    if let captureRecorder, let exchangeID {
      captureRecorder.responseStarted(
        id: exchangeID,
        at: Date(),
        statusCode: Int(status.code),
        headers: capturedHeaders(headers)
      )
    }

    let body: ResponseBody
    if let captureRecorder, let exchangeID {
      body = capturedResponseBody(
        upstreamResponse.body,
        contentType: headers[.contentType],
        exchangeID: exchangeID,
        recorder: captureRecorder
      )
    } else {
      body = ResponseBody(asyncSequence: upstreamResponse.body)
    }
    return Response(
      status: status,
      headers: headers,
      body: body
    )
  }

  private func capturedResponseBody(
    _ upstreamBody: HTTPClientResponse.Body,
    contentType: String?,
    exchangeID: UUIDV7,
    recorder: CaptureRecorder
  ) -> ResponseBody {
    ResponseBody { writer in
      var capture = BodyCapture()
      var iterator = upstreamBody.makeAsyncIterator()
      while true {
        let next: ByteBuffer?
        do {
          next = try await iterator.next()
        } catch {
          finishCapture(
            capture,
            exchangeID: exchangeID,
            contentType: contentType,
            outcome: .failed,
            failure: "response_stream_failed",
            recorder: recorder
          )
          throw error
        }
        guard let buffer = next else { break }
        capture.observe(buffer)
        do {
          try await writer.write(buffer)
        } catch {
          finishCapture(
            capture,
            exchangeID: exchangeID,
            contentType: contentType,
            outcome: .cancelled,
            failure: "client_disconnected",
            recorder: recorder
          )
          throw error
        }
      }
      do {
        try await writer.finish(nil)
      } catch {
        finishCapture(
          capture,
          exchangeID: exchangeID,
          contentType: contentType,
          outcome: .cancelled,
          failure: "client_disconnected",
          recorder: recorder
        )
        throw error
      }
      finishCapture(
        capture,
        exchangeID: exchangeID,
        contentType: contentType,
        outcome: .complete,
        recorder: recorder
      )
    }
  }

  private func finishCapture(
    _ capture: BodyCapture,
    exchangeID: UUIDV7,
    contentType: String?,
    outcome: HTTPExchangeOutcome,
    failure: String? = nil,
    recorder: CaptureRecorder
  ) {
    recorder.store(
      capture.record(
        exchangeID: exchangeID,
        direction: .response,
        contentType: contentType
      )
    )
    recorder.complete(
      id: exchangeID,
      at: Date(),
      outcome: outcome,
      failure: failure
    )
  }

  private func capturedHeaders(_ headers: HTTPFields) -> [CapturedHTTPHeader] {
    headers.map { header in
      capturedHeader(name: header.name.canonicalName, value: header.value)
    }
  }

  private func capturedHeader(name: String, value: String) -> CapturedHTTPHeader {
    capturedHeaderPolicy.capture(name: name, value: value)
  }

  private func requestHeader(_ name: String, in request: Request) -> String? {
    request.headers.first { $0.name.canonicalName == name }?.value
  }

  private func copyRequestHeaders(
    from request: Request,
    to upstreamRequest: inout HTTPClientRequest,
    route: String
  ) {
    let connectionHeaders = connectionTokens(request.headers[values: .connection])
    for field in request.headers {
      let name = field.name.canonicalName
      guard !Self.hopByHopHeaders.contains(name), !connectionHeaders.contains(name), name != "host"
      else { continue }

      if name == "cookie" {
        let value = removingRoutingCookie(from: field.value)
        if !value.isEmpty { upstreamRequest.headers.add(name: field.name.rawName, value: value) }
      } else {
        upstreamRequest.headers.add(name: field.name.rawName, value: field.value)
      }
    }

    if let host = request.head.authority {
      upstreamRequest.headers.add(name: "X-Forwarded-Host", value: host)
    }
    upstreamRequest.headers.add(name: "X-Forwarded-Proto", value: secureCookies ? "https" : "http")
    upstreamRequest.headers.add(name: "X-Forwarded-Prefix", value: "/\(route)")
  }

  private func responseHeaders(from response: HTTPClientResponse) -> HTTPFields {
    let connectionHeaders = connectionTokens(response.headers["connection"])
    // HTTPClient.shared decodes these bodies but preserves the upstream metadata.
    let bodyWasDecoded = response.headers["content-encoding"]
      .contains {
        $0.lowercased() == "gzip" || $0.lowercased() == "deflate"
      }
    var headers = HTTPFields()
    for header in response.headers {
      let name = header.name.lowercased()
      guard !Self.hopByHopHeaders.contains(name), !connectionHeaders.contains(name) else {
        continue
      }
      if bodyWasDecoded && (name == "content-encoding" || name == "content-length") { continue }
      if name == "set-cookie" && header.value.lowercased().hasPrefix("\(cookieName.lowercased())=")
      {
        continue
      }
      guard let fieldName = HTTPField.Name(header.name) else { continue }
      headers.append(HTTPField(name: fieldName, value: header.value))
    }
    return headers
  }

  private func connectionTokens(_ values: [String]) -> Set<String> {
    Set(
      values.flatMap { value in
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      }
    )
  }

  private func removingRoutingCookie(from value: String) -> String {
    value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.lowercased().hasPrefix("\(cookieName.lowercased())=") }
      .joined(separator: "; ")
  }

  private func join(basePath: String, forwardedPath: String) -> String {
    let base =
      basePath == "/" ? "" : basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let forwarded = forwardedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let joined = [base, forwarded].filter { !$0.isEmpty }.joined(separator: "/")
    return "/\(joined)"
  }

  private func resolve(_ request: Request) async -> ResolvedRoute? {
    let path = request.uri.path
    if let route = firstSegment(path), let binding = await registry.binding(route: route) {
      let remainder = path.dropFirst(route.count + 1)
      return (binding, remainder.isEmpty ? "/" : String(remainder), true)
    }

    if let token = request.cookies[cookieName]?.value,
      let binding = await registry.binding(token: token)
    {
      return (binding, path, false)
    }

    return nil
  }

  private func firstSegment(_ path: String) -> String? {
    path.split(separator: "/", omittingEmptySubsequences: true).first.map { String($0) }
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
