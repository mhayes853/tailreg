import AsyncHTTPClient
import HTTPTypes
import Hummingbird
import TailregCore

struct MuxHeaderPolicy: Sendable {
  private static let hopByHopHeaders: Set<String> = [
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "transfer-encoding", "upgrade"
  ]

  /// Dropped from the forwarded request alongside the hop-by-hop headers.
  ///
  /// `host` belongs to the hop the MUX is ending. `accept-encoding` is removed so upstreams
  /// answer with identity encoding: captures stay readable, and because the response is then
  /// passed through untouched the client sees exactly the bytes and the encoding headers the
  /// upstream sent.
  private static let endOfHopRequestHeaders: Set<String> = ["accept-encoding", "host"]

  let cookieName: String
  let publicScheme: PublicScheme
  let capturedHeaderPolicy: CapturedHeaderPolicy

  func requestHeader(_ name: String, in request: Request) -> String? {
    request.headers.first { $0.name.canonicalName == name }?.value
  }

  func capturedHeaders(_ headers: HTTPFields) -> [CapturedHTTPHeader] {
    headers.map { header in
      capturedHeader(name: header.name.canonicalName, value: header.value)
    }
  }

  func capturedHeader(name: String, value: String) -> CapturedHTTPHeader {
    capturedHeaderPolicy.capture(name: name, value: value)
  }

  func copyRequestHeaders(
    from request: Request,
    to upstreamRequest: inout HTTPClientRequest,
    forwardedPrefix: String
  ) {
    let connectionHeaders = connectionTokens(request.headers[values: .connection])
    for field in request.headers {
      let name = field.name.canonicalName
      guard !Self.hopByHopHeaders.contains(name), !connectionHeaders.contains(name),
        !Self.endOfHopRequestHeaders.contains(name)
      else { continue }

      if name == "cookie" {
        let value = removingRoutingCookie(from: field.value)
        if !value.isEmpty { upstreamRequest.headers.add(name: field.name.rawName, value: value) }
      } else {
        upstreamRequest.headers.add(name: field.name.rawName, value: field.value)
      }
    }

    // Replaced rather than appended: Tailscale serve already sets some of these, and an upstream
    // reading the first or the last value must not be able to see a client-supplied one.
    if let host = request.head.authority {
      upstreamRequest.headers.replaceOrAdd(name: "X-Forwarded-Host", value: host)
    }
    upstreamRequest.headers.replaceOrAdd(
      name: "X-Forwarded-Proto",
      value: publicScheme.rawValue
    )
    upstreamRequest.headers.replaceOrAdd(name: "X-Forwarded-Prefix", value: forwardedPrefix)
  }

  func responseHeaders(from response: HTTPClientResponse) -> HTTPFields {
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
}
