import Hummingbird

public struct MultiplexerStatus: ResponseCodable, Equatable, Sendable {
  public let status: String

  public init(status: String) {
    self.status = status
  }
}

public struct Multiplexer: Sendable {
  public struct Configuration: Equatable, Sendable {
    public var adminHost: String
    public var adminPort: Int

    public init(adminHost: String = "127.0.0.1", adminPort: Int = 9100) {
      self.adminHost = adminHost
      self.adminPort = adminPort
    }
  }

  public let configuration: Configuration

  public init(configuration: Configuration = .init()) {
    self.configuration = configuration
  }

  public func buildApplication() -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
    router.get("/status") { _, _ in
      MultiplexerStatus(status: "ok")
    }

    return Application(
      router: router,
      configuration: .init(
        address: .hostname(configuration.adminHost, port: configuration.adminPort),
        serverName: "tailreg-mux"
      )
    )
  }
}
