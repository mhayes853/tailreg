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

  func ensureRunning(for project: ProjectRecord, secureCookies: Bool) async throws
    -> (MuxRunRecord, Bool)
  {
    let lock = FileLock(path: databasePath + ".runtime.lock")
    return try await lock.withLock(.exclusive) {
      if let existing = try await liveRun(for: project.id) {
        let client = MuxAdminClient(port: existing.adminPort)
        if processIsAlive(existing.pid), await client.isReady() {
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
        ] + (secureCookies ? [] : ["--insecure-cookies"])
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
        ingressPort: ports.ingress,
        adminPort: ports.admin
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

  func stop(_ run: MuxRunRecord) async throws {
    if processIsAlive(run.pid) {
      _ = kill(pid_t(run.pid), SIGTERM)
      for _ in 0..<40 where processIsAlive(run.pid) {
        try await Task.sleep(for: .milliseconds(50))
      }
      if processIsAlive(run.pid) { _ = kill(pid_t(run.pid), SIGKILL) }
    }
    try await end(run.id)
  }

  private func liveRun(for projectID: UUIDV7) async throws -> MuxRunRecord? {
    try await database.read { database in
      try MuxRunRecord
        .where { $0.projectID.eq(projectID) && $0.endedAt.is(nil) }
        .order { $0.createdAt.desc() }
        .fetchOne(database)
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
      guard processIsAlive(run.pid) else { throw MuxRuntimeError.exitedBeforeReady }
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

func processIsAlive(_ value: some BinaryInteger) -> Bool {
  let pid = pid_t(truncatingIfNeeded: value)
  guard pid > 0 else { return false }
  if kill(pid, 0) == 0 { return true }
  return errno == EPERM
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
