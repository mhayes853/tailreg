import Foundation
import SQLiteData
import TailregCore
import UUIDV7

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct MuxProcessController: Sendable {
  let database: any DatabaseWriter
  let databasePath: String
  let executableURL: URL
  let terminator: ProcessTerminator<ContinuousClock>

  /// Starts the project MUX, or adopts the one already running.
  ///
  /// Cookies are marked secure only for a tailnet runtime: the loopback listener is served over
  /// plain HTTP, where a secure cookie would never be sent back.
  func ensureRunning(for project: ProjectRecord, exposure: ProjectExposure) async throws
    -> (MuxRunRecord, Bool)
  {
    let lock = FileLock(path: databasePath + ".runtime.lock")
    return try await lock.withLock(.exclusive) {
      if var existing = try await liveRun(for: project.id) {
        let client = MuxAdminClient(port: existing.adminPort)
        if existing.hasMatchingProcess, await client.isReady() {
          // An adopted runtime is about to be published the way *this* invocation asked for, so
          // the record follows the request rather than the invocation that happened to start it.
          if existing.exposure != exposure {
            try await setExposure(exposure, of: existing.id)
            existing.exposure = exposure
          }
          return (existing, false)
        }
        try await end(existing.id)
      }

      let ports = try await allocatePorts(seed: project.rootPath)
      let process = Process()
      process.executableURL = executableURL
      process.arguments =
        [
          "_mux-run",
          "--database-path", databasePath,
          "--mux-id", project.muxID.uuidString,
          "--ingress-port", String(ports.ingress),
          "--admin-port", String(ports.admin)
        ] + (exposure == .tailnet ? [] : ["--insecure-cookies"])
      process.standardInput = FileHandle.nullDevice

      let logURL = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        .appendingPathComponent("mux-\(project.id.uuidString.lowercased()).log")
      _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
      let log = try FileHandle(forWritingTo: logURL)
      try log.seekToEnd()
      process.standardOutput = log
      process.standardError = log
      try process.run()
      try? log.close()

      let run = MuxRunRecord(
        projectID: project.id,
        pid: Int(process.processIdentifier),
        processStartedAt: processStartTime(of: process.processIdentifier),
        ingressPort: ports.ingress,
        adminPort: ports.admin,
        exposure: exposure
      )
      do {
        try await database.write { database in
          try MuxRunRecord.insert { run }.execute(database)
        }
        try await waitUntilReady(run)
        return (run, true)
      } catch {
        if process.isRunning { process.terminate() }
        try? await end(run.id)
        throw error
      }
    }
  }

  /// Stops the project MUX.
  ///
  /// The MUX is signalled as a single process rather than a group: it has no children of its own,
  /// and whether the spawning API makes it a group leader is platform-dependent. It is also not
  /// necessarily this process's child, so its exit can only be observed by probing.
  ///
  /// A recorded PID whose process no longer matches is not signalled: the number may since have
  /// been handed to something unrelated. The record is ended either way, so the project reads as
  /// down.
  @discardableResult
  func stop(_ run: MuxRunRecord) async throws -> TerminationOutcome {
    var outcome = TerminationOutcome.alreadyExited
    if run.hasMatchingProcess {
      outcome = await terminator.terminate(.process(pid_t(run.pid)), observing: .observed)
    }
    try await end(run.id)
    return outcome
  }

  func liveRun(for projectID: UUIDV7) async throws -> MuxRunRecord? {
    try await database.read { database in try MuxRunRecord.live(for: projectID).fetchOne(database) }
  }

  private func setExposure(_ exposure: ProjectExposure, of id: UUIDV7) async throws {
    try await database.write { database in
      try MuxRunRecord.find(id)
        .update { $0.exposure = #bind(exposure) }
        .execute(database)
    }
  }

  private func end(_ id: UUIDV7) async throws {
    try await database.write { database in
      try MuxRunRecord.find(id)
        .update { $0.endedAt = #bind(Date()) }
        .execute(database)
    }
  }

  private func waitUntilReady(_ run: MuxRunRecord) async throws {
    let client = MuxAdminClient(port: run.adminPort)
    for _ in 0..<300 {
      if await client.isReady() { return }
      guard run.hasMatchingProcess else { throw MuxRuntimeError.exitedBeforeReady }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw MuxRuntimeError.readinessTimedOut
  }

  private func allocatePorts(seed: String) async throws -> (ingress: Int, admin: Int) {
    let portProbe = SystemPortProbe()
    let pool = Array(39_100...39_999)
    let offset = seed.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % pool.count }
    var free: [Int] = []
    for index in 0..<pool.count {
      let candidate = pool[(offset + index) % pool.count]
      guard let port = PortNumber(candidate), !(await portProbe.isListening(port: port)) else {
        continue
      }
      free.append(candidate)
      if free.count == 2 { return (free[0], free[1]) }
    }
    throw MuxRuntimeError.noLocalPorts
  }
}

enum MuxRuntimeError: Error, CustomStringConvertible {
  case noLocalPorts
  case exitedBeforeReady
  case readinessTimedOut

  var description: String {
    switch self {
    case .noLocalPorts: "no local ports are available for the project MUX"
    case .exitedBeforeReady: "the project MUX exited before becoming ready"
    case .readinessTimedOut: "timed out waiting for the project MUX"
    }
  }
}
