import Foundation

enum TailscaleServeStatus {
  static func decode(_ data: Data, hostname: String) throws -> [TailscaleBinding] {
    let trimmed = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "null" else { return [] }

    let config: ServeConfigDTO
    do {
      config = try JSONDecoder().decode(ServeConfigDTO.self, from: data)
    } catch {
      throw TailscaleError.malformedOutput(
        command: "serve status --json",
        detail: String(describing: error)
      )
    }

    var bindings: [TailscaleBinding] = []

    for (hostPort, web) in config.web ?? [:] {
      guard let (host, port) = Self.splitHostPort(hostPort) else { continue }
      let proto = Self.webProtocol(forPort: port, tcp: config.tcp)
      let funnel = config.allowFunnel?[hostPort] ?? false

      for (mountPath, handler) in web.handlers ?? [:] {
        guard let target = handler.target else { continue }
        bindings.append(
          TailscaleBinding(
            hostname: host,
            tailnetPort: port,
            proto: proto,
            mountPath: mountPath,
            target: target,
            funnel: funnel
          )
        )
      }
    }

    for (portText, entry) in config.tcp ?? [:] {
      guard let forward = entry.tcpForward, let port = Int(portText) else { continue }
      bindings.append(
        TailscaleBinding(
          hostname: hostname,
          tailnetPort: port,
          proto: entry.terminateTLS == nil ? .tcp : .tlsTerminatedTCP,
          mountPath: "/",
          target: Self.target(fromHostPort: forward),
          funnel: config.allowFunnel?["\(hostname):\(port)"] ?? false
        )
      )
    }

    return bindings.sorted {
      ($0.tailnetPort, $0.mountPath, $0.proto.rawValue)
        < ($1.tailnetPort, $1.mountPath, $1.proto.rawValue)
    }
  }

  private static func webProtocol(
    forPort port: Int,
    tcp: [String: ServeConfigDTO.TCPEntry]?
  ) -> TailscaleServeProtocol {
    guard let entry = tcp?[String(port)] else { return .https }
    return entry.http == true ? .http : .https
  }

  private static func splitHostPort(_ value: String) -> (host: String, port: Int)? {
    guard let separator = value.lastIndex(of: ":") else { return nil }
    guard let port = Int(value[value.index(after: separator)...]) else { return nil }
    return (String(value[..<separator]), port)
  }

  private static func target(fromHostPort value: String) -> TailscaleServeTarget {
    guard let (host, port) = splitHostPort(value), Self.isLoopback(host) else {
      return .proxy(value)
    }
    return .localPort(port)
  }

  static func isLoopback(_ host: String) -> Bool {
    host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
  }
}

// MARK: - Wire format

private struct ServeConfigDTO: Decodable {
  let tcp: [String: TCPEntry]?
  let web: [String: WebEntry]?
  let allowFunnel: [String: Bool]?

  enum CodingKeys: String, CodingKey {
    case tcp = "TCP"
    case web = "Web"
    case allowFunnel = "AllowFunnel"
  }

  struct TCPEntry: Decodable {
    let https: Bool?
    let http: Bool?
    let tcpForward: String?
    let terminateTLS: String?

    enum CodingKeys: String, CodingKey {
      case https = "HTTPS"
      case http = "HTTP"
      case tcpForward = "TCPForward"
      case terminateTLS = "TerminateTLS"
    }
  }

  struct WebEntry: Decodable {
    let handlers: [String: HandlerDTO]?

    enum CodingKeys: String, CodingKey { case handlers = "Handlers" }
  }

  struct HandlerDTO: Decodable {
    let proxy: String?
    let path: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
      case proxy = "Proxy"
      case path = "Path"
      case text = "Text"
    }

    var target: TailscaleServeTarget? {
      if let proxy {
        guard let components = URLComponents(string: proxy),
          let host = components.host,
          let port = components.port,
          TailscaleServeStatus.isLoopback(host)
        else {
          return .proxy(proxy)
        }
        return .localPort(port)
      }
      if let path { return .path(path) }
      if let text { return .text(text) }
      return nil
    }
  }
}
