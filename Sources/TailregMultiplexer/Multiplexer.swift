import Hummingbird
import SQLiteData
import TailregCore

public struct Multiplexer: Sendable {
  public struct Configuration: Equatable, Sendable {
    public var adminHost: String
    public var adminPort: Int
    public var ingressHost: String
    public var ingressPort: Int
    public var routingCookieName: String
    public var secureCookies: Bool
    public var capturedHeaderPolicy: CapturedHeaderPolicy

    public init(
      adminHost: String = "127.0.0.1",
      adminPort: Int = 9100,
      ingressHost: String = "127.0.0.1",
      ingressPort: Int = 9000,
      routingCookieName: String = "__Host-tailreg-route",
      secureCookies: Bool = true,
      capturedHeaderPolicy: CapturedHeaderPolicy = .redactSensitiveValues
    ) {
      self.adminHost = adminHost
      self.adminPort = adminPort
      self.ingressHost = ingressHost
      self.ingressPort = ingressPort
      self.routingCookieName = routingCookieName
      self.secureCookies = secureCookies
      self.capturedHeaderPolicy = capturedHeaderPolicy
    }
  }

  public let configuration: Configuration
  public let registry: BindingRegistry
  public let captureRecorder: CaptureRecorder?

  public init(
    configuration: Configuration = Configuration(),
    registry: BindingRegistry = BindingRegistry(),
    captureRecorder: CaptureRecorder? = nil
  ) {
    self.configuration = configuration
    self.registry = registry
    self.captureRecorder = captureRecorder
  }

  public init(
    configuration: Configuration = Configuration(),
    database: any DatabaseWriter,
    classificationRefiner: (any RequestClassificationRefining)? = nil
  ) {
    self.configuration = configuration
    self.registry = BindingRegistry(database: database)
    self.captureRecorder = CaptureRecorder(
      database: database,
      classificationRefiner: classificationRefiner
    )
  }

  public func buildApplication() -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()
    router.get("/status") { _, _ in
      MultiplexerStatus(status: "ok")
    }

    return Application(
      router: router,
      configuration: ApplicationConfiguration(
        address: .hostname(configuration.adminHost, port: configuration.adminPort),
        serverName: "tailreg-mux"
      )
    )
  }

  public func buildIngressApplication() -> Application<MuxIngressResponder> {
    Application(
      responder: MuxIngressResponder(
        registry: registry,
        cookieName: configuration.routingCookieName,
        secureCookies: configuration.secureCookies,
        capturedHeaderPolicy: configuration.capturedHeaderPolicy,
        captureRecorder: captureRecorder
      ),
      configuration: ApplicationConfiguration(
        address: .hostname(configuration.ingressHost, port: configuration.ingressPort),
        serverName: "tailreg-mux-ingress"
      )
    )
  }
}
