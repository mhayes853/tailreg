import Foundation
import TailregCore

final class FakeTailscaleDaemon: ProcessRunner, @unchecked Sendable {
  struct Handler: Equatable {
    var tailnetPort: Int
    var mountPath: String
    var localPort: Int
    var proto: String
    var funnel: Bool

    init(
      tailnetPort: Int,
      mountPath: String = "/",
      localPort: Int,
      proto: String = "https",
      funnel: Bool = false
    ) {
      self.tailnetPort = tailnetPort
      self.mountPath = mountPath
      self.localPort = localPort
      self.proto = proto
      self.funnel = funnel
    }
  }

  private let lock = NSLock()
  private var handlers: [Handler]
  private var recorded: [[String]] = []

  let hostname: String
  private let backendState: String
  private let serveFailure: (stderr: String, exitCode: Int32)?

  init(
    handlers: [Handler] = [],
    hostname: String = "node.example.ts.net",
    backendState: String = "Running",
    serveFailure: (stderr: String, exitCode: Int32)? = nil
  ) {
    self.handlers = handlers
    self.hostname = hostname
    self.backendState = backendState
    self.serveFailure = serveFailure
  }

  var argvHistory: [[String]] { lock.withLock { recorded } }

  var configuredHandlers: [Handler] {
    lock.withLock {
      handlers.sorted { ($0.tailnetPort, $0.mountPath) < ($1.tailnetPort, $1.mountPath) }
    }
  }

  func argv(startingWith prefix: [String]) -> [[String]] {
    argvHistory.filter { $0.starts(with: prefix) }
  }

  func addHandlerExternally(_ handler: Handler) {
    lock.withLock { handlers.append(handler) }
  }

  func removeAllHandlersExternally() {
    lock.withLock { handlers.removeAll() }
  }

  // MARK: - ProcessRunner

  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?,
    workingDirectory: String?
  ) async throws -> ProcessResult {
    lock.withLock { recorded.append(arguments) }

    switch arguments.first {
    case "status":
      return Self.success(
        """
        { "Version": "1.102.3", "BackendState": "\(backendState)",
          "Self": { "DNSName": "\(hostname)." } }
        """
      )
    case "serve" where arguments.dropFirst().first == "status":
      return Self.success(serveStatusJSON())
    case "serve", "funnel":
      return apply(arguments)
    default:
      return Self.success("")
    }
  }

  // MARK: - Mutation

  private func apply(_ arguments: [String]) -> ProcessResult {
    var proto = "https"
    var tailnetPort = 0
    var mountPath = "/"
    var localPort: Int?
    var isRemoval = false

    for argument in arguments.dropFirst() {
      if argument == "off" {
        isRemoval = true
      } else if argument == "--bg" || argument == "--yes" {
        continue
      } else if argument.hasPrefix("--set-path=") {
        mountPath = String(argument.dropFirst("--set-path=".count))
      } else if argument.hasPrefix("--"), let separator = argument.firstIndex(of: "=") {
        proto = String(argument[argument.index(argument.startIndex, offsetBy: 2)..<separator])
        tailnetPort = Int(argument[argument.index(after: separator)...]) ?? 0
      } else if argument.hasPrefix("http://") {
        localPort = URLComponents(string: argument)?.port
      }
    }

    if isRemoval {
      lock.withLock {
        handlers.removeAll { $0.tailnetPort == tailnetPort && $0.mountPath == mountPath }
      }
      return Self.success("")
    }

    if let serveFailure {
      return ProcessResult(
        exitCode: serveFailure.exitCode,
        standardOutput: Data(),
        standardError: Data(serveFailure.stderr.utf8)
      )
    }

    guard let localPort else { return Self.success("") }
    lock.withLock {
      handlers.removeAll { $0.tailnetPort == tailnetPort && $0.mountPath == mountPath }
      handlers.append(
        Handler(
          tailnetPort: tailnetPort,
          mountPath: mountPath,
          localPort: localPort,
          proto: proto
        )
      )
    }
    return Self.success("")
  }

  // MARK: - Serialisation

  private func serveStatusJSON() -> String {
    let snapshot = lock.withLock { handlers }
    guard !snapshot.isEmpty else { return "{}" }

    var tcp: [String: Any] = [:]
    var web: [String: Any] = [:]
    var allowFunnel: [String: Bool] = [:]

    for handler in snapshot {
      tcp[String(handler.tailnetPort)] = [handler.proto.uppercased(): true]
      let key = "\(hostname):\(handler.tailnetPort)"
      var existing = (web[key] as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
      existing[handler.mountPath] = ["Proxy": "http://127.0.0.1:\(handler.localPort)"]
      web[key] = ["Handlers": existing]
      if handler.funnel {
        allowFunnel[key] = true
      }
    }

    var payload: [String: Any] = ["TCP": tcp, "Web": web]
    if !allowFunnel.isEmpty {
      payload["AllowFunnel"] = allowFunnel
    }
    return String(
      decoding: try! JSONSerialization.data(withJSONObject: payload),
      as: UTF8.self
    )
  }

  private static func success(_ stdout: String) -> ProcessResult {
    ProcessResult(exitCode: 0, standardOutput: Data(stdout.utf8), standardError: Data())
  }
}
