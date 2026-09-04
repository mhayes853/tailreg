import Foundation
import SQLiteData
import TailregCore
import TailregMultiplexer
import UUIDV7

struct DownRequest: Sendable {
  var projectPath: String?
  var applicationNames: [String] = []
}

/// What happened to one application.
///
/// `stopped` and `forced` both mean the application is down; they differ only in whether it had
/// to be killed, which is traced as a warning rather than treated as a failure.
enum ApplicationDownOutcome: Equatable, Sendable {
  case stopped
  case forced(Duration)
  case alreadyDown
  case detached
  case replaced
  case stillRunning(String)

  /// Whether the application ended up down. Only this decides the exit status.
  var isDown: Bool {
    if case .stillRunning = self { return false }
    return true
  }

  var summary: String {
    switch self {
    case .stopped: "stopped"
    case .forced: "forced"
    case .alreadyDown: "already down"
    case .detached: "detached"
    case .replaced: "replaced by a newer run"
    case .stillRunning: "still running"
    }
  }
}

struct DownResult: Sendable {
  let projectName: String
  let applications: [(name: String, outcome: ApplicationDownOutcome)]
  let runtime: ProjectRuntimeTeardown.Outcome?

  /// True when everything selected is down and the runtime is in the state it should be.
  var isClean: Bool {
    guard applications.allSatisfy(\.outcome.isDown) else { return false }
    if case .failed = runtime { return false }
    return true
  }
}

struct DownCoordinator: Sendable {
  private let databasePath: String
  private let executableURL: URL
  private let environment: [String: String]
  private let currentDirectory: URL
  private let console = Console.shared

  init(
    databasePath: String = defaultTailregDatabasePath(),
    executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) {
    self.databasePath = databasePath
    self.executableURL = executableURL
    self.environment = environment
    self.currentDirectory = currentDirectory
  }

  @discardableResult
  func run(_ request: DownRequest) async throws -> DownResult {
    let database = try openTailregDatabase(path: databasePath)
    let terminator = try ProcessTerminator(environment: environment)

    guard
      let project = try await ResolvedProject.lookUp(
        database: database,
        explicitPath: request.projectPath,
        currentDirectory: currentDirectory
      )
    else {
      await console.write("nothing is running for this project")
      return DownResult(projectName: "", applications: [], runtime: nil)
    }

    // Everything that changes a MUX, a route, a binding or a process is serialized here, and the
    // runtime is left in its final state before the lock is released. Nothing else is guaranteed
    // to come along afterwards: a supervisor blocked on this lock may time out and give up.
    let lock = FileLock(path: databasePath + ".runtime.lock")
    let result = try await lock.withLock(.exclusive) {
      try await reconcile(request, project: project, database: database, terminator: terminator)
    }
    await report(result)
    return result
  }

  private func reconcile(
    _ request: DownRequest,
    project: ResolvedProject,
    database: any DatabaseWriter,
    terminator: ProcessTerminator<ContinuousClock>
  ) async throws -> DownResult {
    try await database.write { database in
      try AppRunRecord.reclaimAbandoned(for: project.record.id, in: database)
    }

    let live = try await database.read { database in
      try AppRunRecord.live(for: project.record.id).fetchAll(database)
    }
    // Names this project has ever run, so stopping an ad hoc application twice reports it as
    // already down rather than rejecting a name that `tailreg.toml` never knew about.
    let known = try await database.read { database in
      try AppRunRecord
        .where { $0.belongs(to: project.record.id) }
        .select { $0.name }
        .fetchAll(database)
    }
    let selected = try select(
      request.applicationNames,
      from: live,
      project: project,
      known: Set(known)
    )

    // No MUX means no routes to clear; the records are still ended so the project reads as down.
    let controller = muxController(database: database, terminator: terminator)
    let runtime = try await controller.liveRun(for: project.record.id)
    let admin = runtime.map { MuxAdminClient(port: $0.adminPort) }

    var outcomes: [(name: String, outcome: ApplicationDownOutcome)] = []
    for run in selected {
      let outcome = await stop(run, database: database, terminator: terminator, admin: admin)
      outcomes.append((run.name, outcome))
    }
    let names = Set(selected.map(\.name))
    for name in request.applicationNames where !names.contains(name) {
      outcomes.append((name, .alreadyDown))
    }

    var teardown: ProjectRuntimeTeardown.Outcome?
    if let runtime, let admin {
      teardown = await ProjectRuntimeTeardown(
        admin: admin,
        muxController: controller,
        endpointController: TailnetEndpointController(
          databasePath: databasePath,
          environment: environment
        )
      )
      .stopIfUnused(runtime)
    }
    return DownResult(
      projectName: project.record.name,
      applications: outcomes.sorted { $0.name < $1.name },
      runtime: teardown
    )
  }

  /// Stops one application run.
  ///
  /// The process is stopped *before* the record is ended: a crash between the two leaves a live
  /// record with a dead process, which `reclaimAbandoned` recovers. Ending first would orphan a
  /// running process behind an ended record, which nothing can reclaim.
  private func stop(
    _ run: AppRunRecord,
    database: any DatabaseWriter,
    terminator: ProcessTerminator<ContinuousClock>,
    admin: MuxAdminClient? = nil
  ) async -> ApplicationDownOutcome {
    var outcome: ApplicationDownOutcome = run.ownership == .attached ? .detached : .alreadyDown

    // A recorded PID is not evidence on its own: the kernel recycles PID numbers, and these
    // records outlive reboots. Without a matching start time the process is treated as gone
    // rather than signalled, so `down` never reaches an unrelated process group.
    if run.hasMatchingProcess, let target = run.processGroupID.flatMap(ProcessGroupID.init) {
      switch await terminator.terminate(.processGroup(target), observing: .observed) {
      case .alreadyExited: outcome = .alreadyDown
      case .exitedOnTermination: outcome = .stopped
      case .forced(let elapsed): outcome = .forced(elapsed)
      case .unresponsive: outcome = .stillRunning("the process group survived SIGKILL")
      }
    }

    let won =
      (try? await database.write { database in
        try AppRunRecord.end(run.id, in: database)
      }) ?? false
    guard won else { return await lostRun(run, observed: outcome, database: database) }

    if let admin, let routeID = run.routeID {
      await removeRoute(routeID, admin: admin, application: run.name)
    }
    return outcome
  }

  /// Interprets losing the race to end a run.
  ///
  /// Losing is normal rather than exceptional: an application supervised by a foreground `up`
  /// has its run ended by that supervisor the moment the process dies, which is usually the
  /// moment `down` stopped it. That is not a replacement, and reporting it as one would describe
  /// almost every ordinary `down` as a conflict. Only a *different* live run for the same
  /// application means this one was superseded — and in that case the route belongs to the newer
  /// run, so it is left alone.
  private func lostRun(
    _ run: AppRunRecord,
    observed: ApplicationDownOutcome,
    database: any DatabaseWriter
  ) async -> ApplicationDownOutcome {
    let replacement = try? await database.read { database in
      try AppRunRecord.live(for: run.projectID, name: run.name).fetchOne(database)
    }
    if let replacement = replacement.flatMap({ $0 }), replacement.id != run.id { return .replaced }
    return observed
  }

  /// Removes the run's route by identity.
  ///
  /// The admin API deletes by route name while the record stores the route's ID, so the live
  /// listing is the only thing that can map one to the other without trusting a name that may
  /// since have been reused.
  private func removeRoute(
    _ routeID: UUIDV7,
    admin: MuxAdminClient,
    application: String
  ) async {
    guard let routes = try? await admin.routes() else {
      await console.warning("could not list routes to remove the one for '\(application)'")
      return
    }
    guard let route = routes.first(where: { $0.id == routeID }) else { return }
    do {
      try await admin.remove(route: route.route)
    } catch {
      await console.error("the route for '\(application)' could not be removed: \(error)")
    }
  }

  private func select(
    _ names: [String],
    from live: [AppRunRecord],
    project: ResolvedProject,
    known: Set<String>
  ) throws -> [AppRunRecord] {
    guard !names.isEmpty else { return live }
    let configured = Set(project.specification?.applications.map(\.name) ?? [])
    let running = Dictionary(live.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    for name in names
    where running[name] == nil && !configured.contains(name) && !known.contains(name) {
      throw DownError.unknownApplication(name)
    }
    // Selecting an application does not select its dependencies: `down web` stops web only.
    return names.compactMap { running[$0] }
  }

  private func muxController(
    database: any DatabaseWriter,
    terminator: ProcessTerminator<ContinuousClock>
  ) -> MuxProcessController {
    MuxProcessController(
      database: database,
      databasePath: databasePath,
      executableURL: executableURL,
      terminator: terminator
    )
  }

  private func report(_ result: DownResult) async {
    guard !result.projectName.isEmpty else { return }
    await console.write(result.projectName)
    for application in result.applications {
      await console.write("  \(application.name)  \(application.outcome.summary)")
    }
    switch result.runtime {
    case .stopped: await console.write("  project  stopped")
    case .stillInUse(let routes):
      await console.write("  project  still up (\(routes) route\(routes == 1 ? "" : "s"))")
    case .failed, .none: break
    }

    for application in result.applications {
      switch application.outcome {
      case .forced(let elapsed):
        await console.warning(
          "\(application.name) did not stop within \(elapsed); killed"
        )
      case .replaced:
        await console.warning("\(application.name) was replaced by a newer run; left alone")
      case .stillRunning(let reason):
        await console.error("\(application.name) is still running: \(reason)")
      case .stopped, .alreadyDown, .detached: break
      }
    }
    if case .failed(let reason) = result.runtime {
      await console.error("the project runtime was not fully removed: \(reason)")
    }
  }
}

enum DownError: Error, CustomStringConvertible, Sendable {
  case unknownApplication(String)
  case notFullyStopped

  var description: String {
    switch self {
    case .unknownApplication(let name): "unknown application '\(name)'"
    case .notFullyStopped: "the project did not fully stop"
    }
  }
}
