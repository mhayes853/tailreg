import Foundation
import TailregCore
import TailregMultiplexer

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct MuxAdminClient: Sendable {
  let port: Int

  func isReady() async -> Bool {
    (try? await data(path: "/status", method: "GET")) != nil
  }

  func routes() async throws -> [MuxRouteResponse] {
    try await request(path: "/routes", method: "GET")
  }

  func register(_ registration: MuxRouteRegistrationRequest) async throws -> MuxRouteResponse {
    try await request(
      path: "/routes",
      method: "POST",
      body: try JSONEncoder().encode(registration)
    )
  }

  func update(route: String, upstream: URL, pathMode: MuxRoutePathMode) async throws
    -> MuxRouteResponse
  {
    try await request(
      path: "/routes/\(route)",
      method: "PUT",
      body: try JSONEncoder()
        .encode(
          MuxRouteUpdateRequest(upstreamURL: upstream.absoluteString, pathMode: pathMode)
        )
    )
  }

  func remove(route: String) async throws {
    _ = try await data(path: "/routes/\(route)", method: "DELETE", statuses: [204, 404])
  }

  private func request<Response: Decodable>(path: String, method: String, body: Data? = nil)
    async throws -> Response
  {
    try JSONDecoder()
      .decode(
        Response.self,
        from: try await data(path: path, method: method, body: body)
      )
  }

  private func data(
    path: String,
    method: String,
    body: Data? = nil,
    statuses: Set<Int> = [200]
  ) async throws -> Data {
    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
      throw MuxAdminError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    request.timeoutInterval = 2
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw MuxAdminError.invalidResponse }
    guard statuses.contains(response.statusCode) else {
      throw MuxAdminError.status(response.statusCode)
    }
    return data
  }
}

enum MuxAdminError: Error, CustomStringConvertible {
  case invalidURL
  case invalidResponse
  case status(Int)

  var description: String {
    switch self {
    case .invalidURL: "invalid MUX admin URL"
    case .invalidResponse: "invalid response from MUX admin API"
    case .status(let status): "MUX admin API returned HTTP \(status)"
    }
  }
}
