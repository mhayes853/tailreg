import Foundation
import SQLiteData

public actor TailscaleBinder {
  public static let defaultClaimGracePeriod: TimeInterval = 30

  private let cli: TailscaleCLI
  private let portProbe: any PortProbe
  private let database: any DatabaseWriter
  private let fileLock: FileLock
  private let claimGracePeriod: TimeInterval
  private let gate = AsyncGate()

  public init(
    binaryPath: String,
    runner: any ProcessRunner,
    portProbe: any PortProbe,
    database: any DatabaseWriter,
    claimGracePeriod: TimeInterval = TailscaleBinder.defaultClaimGracePeriod
  ) {
    self.cli = TailscaleCLI(binaryPath: binaryPath, runner: runner)
    self.portProbe = portProbe
    self.database = database
    self.fileLock = FileLock(path: database.path + ".lock")
    self.claimGracePeriod = claimGracePeriod
  }

  public static func standard(
    searchPaths: [String] = TailscaleLocator.defaultSearchPaths(),
    databasePath: String = defaultTailregDatabasePath(),
    claimGracePeriod: TimeInterval = TailscaleBinder.defaultClaimGracePeriod
  ) throws -> TailscaleBinder {
    TailscaleBinder(
      binaryPath: try TailscaleLocator(searchPaths: searchPaths).locate(),
      runner: SystemProcessRunner(),
      portProbe: SystemPortProbe(),
      database: try openTailregDatabase(path: databasePath),
      claimGracePeriod: claimGracePeriod
    )
  }

  // MARK: - Inspection

  public func bindings() async throws -> [TailscaleBinding] {
    try await gate.withGate {
      try await self.fileLock.withLock(.shared) {
        try await self.snapshot()
      }
    }
  }

  // MARK: - Binding

  @discardableResult
  public func bind(
    localPort: Int,
    to tailnetPort: TailscaleTailnetPort = .auto,
    mountPath: String = "/"
  ) async throws -> TailscaleBinding {
    try await gate.withGate {
      try await self.fileLock.withLock(.exclusive) {
        try await self.performBind(localPort: localPort, to: tailnetPort, mountPath: mountPath)
      }
    }
  }

  // MARK: - Unbinding

  @discardableResult
  public func unbind(tailnetPort: Int) async throws -> [TailscaleBinding] {
    try await gate.withGate {
      try await self.fileLock.withLock(.exclusive) {
        try await self.performRemove { $0.tailnetPort == tailnetPort }
      }
    }
  }

  @discardableResult
  public func unbind(localPort: Int) async throws -> [TailscaleBinding] {
    try await gate.withGate {
      try await self.fileLock.withLock(.exclusive) {
        try await self.performRemove { $0.localPort == localPort }
      }
    }
  }

  @discardableResult
  public func unbindAll() async throws -> [TailscaleBinding] {
    try await gate.withGate {
      try await self.fileLock.withLock(.exclusive) {
        try await self.performRemove(\.isManaged)
      }
    }
  }

  // MARK: - Operations

  private func performBind(
    localPort: Int,
    to tailnetPort: TailscaleTailnetPort,
    mountPath: String
  ) async throws -> TailscaleBinding {
    let status = try await requireRunning()

    guard await portProbe.isListening(port: localPort) else {
      throw TailscaleError.noLocalServerListening(port: localPort)
    }

    let live = try await cli.serveStatus(hostname: status.dnsName)
    let resolvedPort = try resolveTailnetPort(tailnetPort, mountPath: mountPath, live: live)
    let record = TailscaleBindingRecord(
      localPort: localPort,
      tailnetPort: resolvedPort,
      proto: .https,
      mountPath: mountPath,
      createdAt: Date()
    )

    try await claim(record)
    do {
      try await cli.serve(
        localPort: localPort,
        tailnetPort: resolvedPort,
        mountPath: mountPath
      )
    } catch {
      try? await releaseClaim(
        tailnetPort: resolvedPort,
        proto: .https,
        mountPath: mountPath
      )
      throw error
    }

    let confirmed = try await cli.serveStatus(hostname: status.dnsName)
    guard
      var binding = confirmed.first(where: {
        $0.tailnetPort == resolvedPort && $0.mountPath == mountPath
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
      try await releaseClaim(
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
    let records = try await database.read { db in
      try TailscaleBindingRecord
        .order { ($0.tailnetPort, $0.mountPath) }
        .fetchAll(db)
    }

    let now = Date()
    var surviving: [TailscaleBindingRecord] = []
    var dead: [UUIDV7] = []
    for record in records {
      if live.contains(where: record.claims) {
        surviving.append(record)
      } else if now.timeIntervalSince(record.createdAt) > claimGracePeriod {
        dead.append(record.id)
      }
    }
    try await discardClaims(dead)

    return live.map { binding in
      var binding = binding
      binding.isManaged = surviving.contains { $0.claims(binding) }
      return binding
    }
  }

  // MARK: - Persistence

  private func claim(_ record: TailscaleBindingRecord) async throws {
    try await database.write { db in
      try TailscaleBindingRecord
        .insert {
          record
        } onConflict: {
          ($0.tailnetPort, $0.proto, $0.mountPath)
        } doUpdate: { updates, excluded in
          updates.localPort = excluded.localPort
          updates.createdAt = excluded.createdAt
        }
        .execute(db)
    }
  }

  private func releaseClaim(
    tailnetPort: Int,
    proto: TailscaleServeProtocol,
    mountPath: String
  ) async throws {
    try await database.write { db in
      try TailscaleBindingRecord
        .where {
          $0.tailnetPort.eq(tailnetPort) && $0.proto.eq(proto) && $0.mountPath.eq(mountPath)
        }
        .delete()
        .execute(db)
    }
  }

  private func discardClaims(_ ids: [UUIDV7]) async throws {
    guard !ids.isEmpty else { return }
    try await database.write { db in
      try TailscaleBindingRecord.find(ids).delete().execute(db)
    }
  }

  // MARK: - Daemon

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
