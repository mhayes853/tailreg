import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird

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

  public init(
    registry: BindingRegistry,
    cookieName: String,
    secureCookies: Bool
  ) {
    self.registry = registry
    self.cookieName = cookieName
    self.secureCookies = secureCookies
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

    if request.method != .get && request.method != .head {
      let length: HTTPClientRequest.Body.Length =
        request.headers[.contentLength].flatMap { Int64($0) }.map { .known($0) } ?? .unknown
      upstreamRequest.body = .stream(request.body, length: length)
    }

    let upstreamResponse = try await HTTPClient.shared.execute(
      upstreamRequest,
      timeout: .hours(24)
    )
    let headers = responseHeaders(from: upstreamResponse)
    return Response(
      status: HTTPResponse.Status(code: Int(upstreamResponse.status.code)),
      headers: headers,
      body: ResponseBody(asyncSequence: upstreamResponse.body)
    )
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
    var headers = HTTPFields()
    for header in response.headers {
      let name = header.name.lowercased()
      guard !Self.hopByHopHeaders.contains(name), !connectionHeaders.contains(name) else {
        continue
      }
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
