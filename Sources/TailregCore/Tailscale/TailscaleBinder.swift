import Foundation
import SQLiteData
import UUIDV7

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

  public func history(limit: Int = 100) async throws -> [TailscaleBindingRecord] {
    try await database.read { db in
      try TailscaleBindingRecord
        .order { ($0.createdAt.desc(), $0.id.desc()) }
        .limit(limit)
        .fetchAll(db)
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
    let claimed = try await reconcile(against: live, now: Date())
    let resolvedPort = try resolveTailnetPort(
      tailnetPort,
      mountPath: mountPath,
      live: live,
      claimed: claimed
    )

    let record = TailscaleBindingRecord(
      hostname: status.dnsName,
      localPort: localPort,
      tailnetPort: resolvedPort,
      proto: .https,
      mountPath: mountPath,
      status: .pending,
      createdAt: Date()
    )
    try await open(record)

    do {
      try await cli.serve(
        localPort: localPort,
        tailnetPort: resolvedPort,
        mountPath: mountPath
      )
    } catch {
      try? await close([record.id], reason: .failed, at: Date())
      throw error
    }

    let confirmed = try await cli.serveStatus(hostname: status.dnsName)
    guard
      var binding = confirmed.first(where: {
        $0.tailnetPort == resolvedPort && $0.mountPath == mountPath
      })
    else {
      try? await close([record.id], reason: .failed, at: Date())
      throw TailscaleError.bindingNotFound
    }

    try await activate([record.id])
    binding.recordID = record.id
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
      if let id = binding.recordID {
        try await close([id], reason: .unbound, at: Date())
      }
    }
    return targets
  }

  private func snapshot() async throws -> [TailscaleBinding] {
    let status = try await requireRunning()
    let live = try await cli.serveStatus(hostname: status.dnsName)
    let claimed = try await reconcile(against: live, now: Date())

    return live.map { binding in
      var binding = binding
      binding.recordID = claimed.first { $0.claims(binding) }?.id
      return binding
    }
  }

  private func reconcile(
    against live: [TailscaleBinding],
    now: Date
  ) async throws -> [TailscaleBindingRecord] {
    let records = try await database.read { db in
      try TailscaleBindingRecord
        .where { $0.endedAt.is(nil) }
        .order { ($0.tailnetPort, $0.mountPath) }
        .fetchAll(db)
    }

    var surviving: [TailscaleBindingRecord] = []
    var confirmed: [UUIDV7] = []
    var expired: [UUIDV7] = []

    for record in records {
      if live.contains(where: record.claims) {
        surviving.append(record)
        if record.status == .pending {
          confirmed.append(record.id)
        }
      } else if now.timeIntervalSince(record.createdAt) > claimGracePeriod {
        expired.append(record.id)
      } else {
        surviving.append(record)
      }
    }

    try await activate(confirmed)
    try await close(expired, reason: .expired, at: now)
    return surviving
  }

  // MARK: - Persistence

  private func open(_ record: TailscaleBindingRecord) async throws {
    try await database.write { db in
      try TailscaleBindingRecord.insert { record }.execute(db)
    }
  }

  private func activate(_ ids: [UUIDV7]) async throws {
    guard !ids.isEmpty else { return }
    try await database.write { db in
      try TailscaleBindingRecord
        .where { $0.id.in(ids) && $0.endedAt.is(nil) }
        .update { $0.status = #bind(TailscaleBindingStatus.active) }
        .execute(db)
    }
  }

  private func close(
    _ ids: [UUIDV7],
    reason: TailscaleBindingEndReason,
    at date: Date
  ) async throws {
    guard !ids.isEmpty else { return }
    try await database.write { db in
      try TailscaleBindingRecord
        .where { $0.id.in(ids) && $0.endedAt.is(nil) }
        .update {
          $0.status = #bind(TailscaleBindingStatus.ended)
          $0.endedAt = #bind(date)
          $0.endReason = #bind(reason)
        }
        .execute(db)
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
    live: [TailscaleBinding],
    claimed: [TailscaleBindingRecord]
  ) throws -> Int {
    switch requested {
    case .explicit(let port):
      if let clash = live.first(where: { $0.tailnetPort == port && $0.mountPath == mountPath }) {
        throw TailscaleError.tailnetPortInUse(
          port: port,
          existingTarget: String(describing: clash.target)
        )
      }
      if let clash = claimed.first(where: { $0.tailnetPort == port && $0.mountPath == mountPath }) {
        throw TailscaleError.tailnetPortInUse(
          port: port,
          existingTarget: String(describing: TailscaleServeTarget.localPort(clash.localPort))
        )
      }
      return port

    case .auto:
      let occupied = Set(live.map(\.tailnetPort)).union(claimed.map(\.tailnetPort))
      guard
        let free = TailscaleTailnetPort.autoAllocationPool.first(where: { !occupied.contains($0) })
      else {
        throw TailscaleError.noAvailableTailnetPort
      }
      return free
    }
  }
}
