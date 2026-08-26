import Foundation

public actor TailscaleBinder {
  private let cli: TailscaleCLI
  private let portProbe: any PortProbe
  private let registry: TailscaleBindingRegistry
  private let now: @Sendable () -> Date

  private let gate = AsyncGate()

  public init(
    cli: TailscaleCLI,
    portProbe: any PortProbe,
    registry: TailscaleBindingRegistry,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.cli = cli
    self.portProbe = portProbe
    self.registry = registry
    self.now = now
  }

  public static func standard(
    searchPaths: [String] = TailscaleLocator.defaultSearchPaths(),
    registryPath: String = TailscaleBindingRegistry.defaultPath()
  ) throws -> TailscaleBinder {
    let binaryPath = try TailscaleLocator(searchPaths: searchPaths).locate()
    return TailscaleBinder(
      cli: TailscaleCLI(binaryPath: binaryPath, runner: SystemProcessRunner()),
      portProbe: SystemPortProbe(),
      registry: TailscaleBindingRegistry(path: registryPath)
    )
  }

  // MARK: - Inspection

  public func installation() async throws -> TailscaleInstallation {
    let status = try await cli.status()
    return TailscaleInstallation(
      binaryPath: cli.binaryPath,
      version: try await cli.version(),
      backendState: status.backendState,
      dnsName: status.dnsName
    )
  }

  public func bindings() async throws -> [TailscaleBinding] {
    try await gate.withGate { try await self.snapshot() }
  }

  public func managedBindings() async throws -> [TailscaleBinding] {
    try await gate.withGate { try await self.snapshot().filter(\.isManaged) }
  }

  // MARK: - Binding

  @discardableResult
  public func bind(
    localPort: Int,
    to tailnetPort: TailscaleTailnetPort = .auto,
    proto: TailscaleServeProtocol = .https,
    mountPath: String = "/",
    funnel: Bool = false
  ) async throws -> TailscaleBinding {
    try await gate.withGate {
      try await self.performBind(
        localPort: localPort,
        to: tailnetPort,
        proto: proto,
        mountPath: mountPath,
        funnel: funnel
      )
    }
  }

  // MARK: - Unbinding

  @discardableResult
  public func unbind(tailnetPort: Int) async throws -> [TailscaleBinding] {
    try await gate.withGate {
      try await self.performRemove { $0.tailnetPort == tailnetPort }
    }
  }

  @discardableResult
  public func unbind(localPort: Int) async throws -> [TailscaleBinding] {
    try await gate.withGate {
      try await self.performRemove { $0.localPort == localPort }
    }
  }

  @discardableResult
  public func unbindAll() async throws -> [TailscaleBinding] {
    try await gate.withGate {
      try await self.performRemove(\.isManaged)
    }
  }

  // MARK: - Operations

  private func performBind(
    localPort: Int,
    to tailnetPort: TailscaleTailnetPort,
    proto: TailscaleServeProtocol,
    mountPath: String,
    funnel: Bool
  ) async throws -> TailscaleBinding {
    let status = try await requireRunning()

    guard await portProbe.isListening(port: localPort) else {
      throw TailscaleError.noLocalServerListening(port: localPort)
    }

    let live = try await cli.serveStatus(hostname: status.dnsName)
    let resolvedPort = try resolveTailnetPort(tailnetPort, mountPath: mountPath, live: live)

    try await registry.add(
      TailscaleBindingRecord(
        localPort: localPort,
        tailnetPort: resolvedPort,
        proto: proto,
        mountPath: mountPath,
        createdAt: now()
      )
    )
    do {
      try await cli.serve(
        localPort: localPort,
        tailnetPort: resolvedPort,
        proto: proto,
        mountPath: mountPath,
        funnel: funnel
      )
    } catch {
      try? await registry.removeClaim(
        tailnetPort: resolvedPort,
        proto: proto,
        mountPath: mountPath
      )
      throw error
    }

    let confirmed = try await cli.serveStatus(hostname: status.dnsName)
    guard
      var binding = confirmed.first(where: {
        $0.tailnetPort == resolvedPort && $0.proto == proto && $0.mountPath == mountPath
      })
    else {
      throw TailscaleError.bindingNotFound
    }
    binding.isManaged = true
    return binding
  }

  private func performRemove(
    _ matches: (TailscaleBinding) -> Bool
  ) async throws -> [TailscaleBinding] {
    let targets = try await snapshot().filter(matches)
    for binding in targets {
      try await cli.serveOff(
        tailnetPort: binding.tailnetPort,
        proto: binding.proto,
        mountPath: binding.mountPath
      )
      try await registry.removeClaim(
        tailnetPort: binding.tailnetPort,
        proto: binding.proto,
        mountPath: binding.mountPath
      )
    }
    return targets
  }

  private func snapshot() async throws -> [TailscaleBinding] {
    let status = try await requireRunning()
    let live = try await cli.serveStatus(hostname: status.dnsName)
    let records = try await registry.records()

    let surviving = records.filter { record in live.contains(where: record.claims) }
    if surviving.count != records.count {
      try await registry.replaceAll(with: surviving)
    }

    return live.map { binding in
      var binding = binding
      binding.isManaged = surviving.contains { $0.claims(binding) }
      return binding
    }
  }

  private func requireRunning() async throws -> TailscaleStatus {
    let status = try await cli.status()
    guard status.isRunning else {
      throw TailscaleError.daemonNotRunning(state: status.backendState)
    }
    return status
  }

  private func resolveTailnetPort(
    _ requested: TailscaleTailnetPort,
    mountPath: String,
    live: [TailscaleBinding]
  ) throws -> Int {
    switch requested {
    case .explicit(let port):
      if let clash = live.first(where: { $0.tailnetPort == port && $0.mountPath == mountPath }) {
        throw TailscaleError.tailnetPortInUse(
          port: port,
          existingTarget: String(describing: clash.target)
        )
      }
      return port

    case .auto:
      let occupied = Set(live.map(\.tailnetPort))
      guard
        let free = TailscaleTailnetPort.autoAllocationPool.first(where: { !occupied.contains($0) })
      else {
        throw TailscaleError.noAvailableTailnetPort
      }
      return free
    }
  }
}
