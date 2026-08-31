import AsyncHTTPClient
import HTTPTypes
import Hummingbird
import TailregCore

struct MuxHeaderPolicy: Sendable {
  private static let hopByHopHeaders: Set<String> = [
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "transfer-encoding", "upgrade"
  ]

  let cookieName: String
  let secureCookies: Bool
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

  func responseHeaders(from response: HTTPClientResponse) -> HTTPFields {
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
}
