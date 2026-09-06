import Foundation
import Operation
import SQLiteData
import TailregCore
import TailregMultiplexer
import UUIDV7

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// What one `up` invocation was asked to bring up.
///
/// The flag combinations the command line allows are resolved into these cases once, at the
/// boundary, so nothing downstream has to ask again whether a command and an attach URL were
/// both given, or a port was set for something that does not listen on one.
struct UpRequest: Sendable {
  enum Selection: Sendable {
    /// Configured applications by name, with their dependencies; empty means all of them.
    case configured([String])
    /// One application named on the command line, which `tailreg.toml` need not describe.
    case adHoc(name: String, route: MuxRouteName?, source: AdHocSource)
  }

  enum AdHocSource: Sendable {
    /// The argv after `--`. Its working directory is the project root.
    case command([String], port: PortNumber?)
    case attached(LoopbackURL)
  }

  var projectPath: String?
  var selection: Selection
  var tailnetPort: PortNumber?
  var localOnly = false
}

struct UpResult: Sendable {
  let projectName: String
  let baseURL: URL
  let applications: [StartedApplication]
}

struct StartedApplication: Sendable {
  let name: String
  let route: MuxRouteName?
  let publicURL: URL?
  let pid: Int32?
}

struct UpCoordinator: Sendable {
  private let databasePath: String
  private let executableURL: URL
  private let environment: [String: String]
  private let currentDirectory: URL
  private let portProbe: any PortProbe
  private let listenerLocator: any ListeningProcessLocator
  private let console = Console.shared

  init(
    databasePath: String = defaultTailregDatabasePath(),
    executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    portProbe: any PortProbe = SystemPortProbe(),
    listenerLocator: any ListeningProcessLocator = SystemListeningProcessLocator()
  ) {
    self.databasePath = databasePath
    self.executableURL = executableURL
    self.environment = environment
    self.currentDirectory = currentDirectory
    self.portProbe = portProbe
    self.listenerLocator = listenerLocator
  }

  func run(
    _ request: UpRequest,
    onReady: @Sendable (UpResult) async -> Void = { _ in }
  ) async throws -> UpResult {
    let database = try openTailregDatabase(path: databasePath)
    return try await recordingCommandRun("up", in: database) { recorder in
      try await reconcile(request, database: database, recorder: recorder, onReady: onReady)
    }
  }

  private func reconcile(
    _ request: UpRequest,
    database: any DatabaseWriter,
    recorder: OperationRecorder,
    onReady: @Sendable (UpResult) async -> Void
  ) async throws -> UpResult {
    let terminator = try ProcessTerminator(environment: environment)
    let project = try await ResolvedProject.resolve(
      database: database,
      explicitPath: request.projectPath,
      currentDirectory: currentDirectory
    )
    await recorder.attach(project: project.record.id)
    try await database.write { database in
      try AppRunRecord.reclaimAbandoned(for: project.record.id, in: database)
    }
    let levels = try applicationLevels(for: request, project: project)
    let muxController = MuxProcessController(
      database: database,
      databasePath: databasePath,
      executableURL: executableURL,
      terminator: terminator
    )
    let exposure: ProjectExposure = request.localOnly ? .local : .tailnet
    let ensured = try await muxController.ensureRunning(
      for: project.record,
      exposure: exposure
    )
    let runtime = ensured.run
    if request.localOnly, runtime.exposure == .tailnet {
      await console.warning(
        "this project is already published on the tailnet; --local-only leaves that binding in place"
      )
    }
    let endpointController = TailnetEndpointController(
      databasePath: databasePath,
      environment: environment
    )
    let endpoint: TailnetEndpoint
    do {
      endpoint = try await endpointController.ensure(
        ingressPort: runtime.ingressPort,
        exposure: exposure,
        requestedPort: request.tailnetPort
      )
    } catch {
      if ensured.wasStarted { try? await muxController.stop(runtime) }
      throw error
    }
    let baseURL = endpoint.url

    let admin = MuxAdminClient(port: runtime.adminPort)
    let teardown = ProjectRuntimeTeardown(
      admin: admin,
      muxController: muxController,
      endpointController: endpointController
    )
    var running: [RunningApplication] = []
    do {
      for level in levels {
        let started = try await withThrowingTaskGroup(of: RunningApplication.self) { group in
          for application in level {
            group.addTask {
              try await #run(
                $startApplication(
                  application,
                  endpoint: endpoint,
                  admin: admin,
                  terminator: terminator,
                  database: database,
                  projectID: project.record.id
                )
              )
            }
          }
          var levelResults: [RunningApplication] = []
          for try await result in group { levelResults.append(result) }
          return levelResults.sorted { $0.name < $1.name }
        }
        running.append(contentsOf: started)
      }
    } catch {
      await rollback(running, admin: admin, terminator: terminator, database: database)
      await stopRuntimeIfUnused(teardown, runtime: runtime)
      throw error
    }

    let result = UpResult(
      projectName: project.record.name,
      baseURL: baseURL,
      applications: running.map { $0.started(baseURL: baseURL) }
    )
    await printSummary(result)
    await onReady(result)

    let managed = running.filter { $0.process != nil }
    guard !managed.isEmpty else { return result }
    let signalSupervisor = SignalSupervisor { stopManaged(managed, terminator: terminator) }
    signalSupervisor.start()
    defer { signalSupervisor.stop() }

    await withTaskCancellationHandler {
      await withTaskGroup(of: (RunningApplication, ProcessExit).self) { group in
        for application in managed {
          group.addTask {
            (application, await application.process!.waitForExit())
          }
        }
        for await (application, exit) in group {
          for task in application.outputTasks { task.cancel() }
          if await endRun(application, database: database) {
            await removeRouteIfCurrent(application, admin: admin)
          }
          await console.write(
            "[\(application.name)] \(Self.describe(exit))",
            toStandardError: exit.code != 0 || exit.wasTerminatedBySignal
          )
        }
      }
    } onCancel: {
      stopManaged(managed, terminator: terminator)
    }

    await stopRuntimeIfUnused(teardown, runtime: runtime)
    return result
  }

  /// Requests a graceful stop from a synchronous context and escalates asynchronously.
  ///
  /// Signal handlers and cancellation callbacks cannot await, so the stop signal goes out inline
  /// and keeps Ctrl-C responsive. Waiting out the grace period and escalating to SIGKILL is
  /// policy, so it runs through the shared terminator instead of being reimplemented here. The
  /// escalation is conditional on the group still running, which is what keeps a late SIGKILL
  /// from reaching a recycled process group.
  private func stopManaged(
    _ managed: [RunningApplication],
    terminator: ProcessTerminator<ContinuousClock>
  ) {
    for application in managed {
      guard let process = application.process, let group = ProcessGroupID(process.pid) else {
        continue
      }
      terminator.requestStop(.processGroup(group))
      Task {
        let outcome = await terminator.terminate(.processGroup(group), observing: .owned(process))
        switch outcome {
        case .forced: await console.warning("\(application.name) \(outcome)")
        case .unresponsive: await console.error("\(application.name) \(outcome)")
        case .alreadyExited, .exitedOnTermination: break
        }
      }
    }
  }

  private static func describe(_ exit: ProcessExit) -> String {
    exit.wasTerminatedBySignal
      ? "terminated by signal \(exit.code)"
      : "exited with status \(exit.code)"
  }

  private func applicationLevels(for request: UpRequest, project: ResolvedProject) throws
    -> [[ApplicationSpecification]]
  {
    switch request.selection {
    case .adHoc(let name, let route, let source):
      let application = try ApplicationSpecification(
        name: name,
        source: try applicationSource(source, name: name, projectRoot: project.root),
        route: route
      )
      return [[application]]
    case .configured(let names):
      guard let specification = project.specification else {
        throw UpError.configurationRequired
      }
      return try specification.selected(names)
    }
  }

  /// An ad hoc application's source, with the argv turned into a command rooted at the project.
  private func applicationSource(
    _ source: UpRequest.AdHocSource,
    name: String,
    projectRoot: URL
  ) throws -> ApplicationSpecification.Source {
    switch source {
    case .attached(let url):
      return .attached(url)
    case .command(let arguments, let port):
      guard let executable = arguments.first else {
        throw ProjectSpecificationError.emptyCommand(name)
      }
      return .command(
        ProcessCommand(
          executable: executable,
          arguments: Array(arguments.dropFirst()),
          workingDirectory: projectRoot
        ),
        port: port
      )
    }
  }

  /// Brings one application up: launch it if it is ours, wait for it, record it, publish it.
  ///
  /// The order is the invariant. Nothing is launched onto a port that already answers, nothing
  /// is recorded before the listener is confirmed to be ours, and no route is published before
  /// the run that owns it exists. Anything that fails after the launch unwinds what this call
  /// created and leaves the rest of the invocation to roll itself back.
  @OperationRequest
  private func startApplication(
    _ specification: ApplicationSpecification,
    endpoint: TailnetEndpoint,
    admin: MuxAdminClient,
    terminator: ProcessTerminator<ContinuousClock>,
    database: any DatabaseWriter,
    projectID: UUIDV7
  ) async throws -> RunningApplication {
    let launched = try await #run($launchApplication(specification, endpoint: endpoint))
    do {
      try await waitUntilReady(specification, process: launched?.process)
      let appRun = try await record(
        specification,
        process: launched?.process,
        endpoint: endpoint,
        database: database,
        projectID: projectID
      )
      do {
        return try await publish(
          specification,
          run: appRun,
          process: launched?.process,
          outputTasks: launched?.outputTasks ?? [],
          admin: admin,
          database: database
        )
      } catch {
        // The run was recorded but never published. An attached run has no process for
        // `reclaimAbandoned` to disprove, so it would otherwise block this application until the
        // next `down`.
        _ = try? await database.write { database in try AppRunRecord.end(appRun.id, in: database) }
        throw error
      }
    } catch {
      if let launched {
        await terminator.stopProcessGroup(of: launched.process)
        for task in launched.outputTasks { task.cancel() }
      }
      throw error
    }
  }

  /// Launches a managed application's command, or nothing at all for an attached one.
  ///
  /// The command runs through `_exec` so that it leads its own process group, and it is told
  /// where the project and its own route are reachable, which is what lets a frontend address a
  /// sibling API through the MUX rather than through a port the user had to hardcode.
  @OperationRequest
  private func launchApplication(
    _ specification: ApplicationSpecification,
    endpoint: TailnetEndpoint
  ) async throws -> LaunchedApplication? {
    guard var command = specification.command else { return nil }
    // A port that already answers would pass the readiness probe on its first tick, and the
    // route would be published to whatever is there rather than to the process about to start.
    if let port = specification.listenerPort {
      try await requireFree(port: port, application: specification.name)
    }
    command.environment = environment.merging(command.environment) { _, configured in configured }
    command.environment["TAILREG_PROJECT_URL"] = endpoint.url.absoluteString
    if let route = specification.exposure?.route {
      command.environment["TAILREG_APP_PATH"] = "/\(route)/"
    }
    if let port = specification.listenerPort {
      command.environment["TAILREG_PORT"] = port.description
    }
    let supervisedCommand = ProcessCommand(
      executable: executableURL.path,
      arguments: [SupervisedCommand.marker, command.executable] + command.arguments,
      workingDirectory: command.workingDirectory,
      environment: command.environment
    )
    let process = try SystemProcessLauncher().launch(supervisedCommand)
    return LaunchedApplication(
      process: process,
      outputTasks: outputTasksFor(process, name: specification.name)
    )
  }

  /// Waits for the application's declared port, and for the answer to have come from it.
  private func waitUntilReady(
    _ specification: ApplicationSpecification,
    process: LaunchedProcess?
  ) async throws {
    guard let port = specification.listenerPort else { return }
    try await waitForListener(port: port, process: process, application: specification.name)
    // The pre-launch check races with anything else that wants the port. The listener that
    // finally answered has to be the process this invocation started.
    if let process {
      try await #run($confirmPortOwnership(of: port, by: process, application: specification.name))
    }
  }

  /// Records the run before the route is published.
  ///
  /// A run without a route can be reconciled later, whereas a published route with no owning run
  /// has nothing to identify who may remove it. The unique index on live runs is what makes a
  /// second `up` of the same application a reported conflict rather than two supervisors.
  private func record(
    _ specification: ApplicationSpecification,
    process: LaunchedProcess?,
    endpoint: TailnetEndpoint,
    database: any DatabaseWriter,
    projectID: UUIDV7
  ) async throws -> AppRunRecord {
    let appRun = AppRunRecord(
      projectID: projectID,
      name: specification.name,
      ownership: specification.ownership,
      bindingID: endpoint.bindingID,
      pid: process.map { Int($0.pid) },
      processGroupID: process.flatMap { ProcessGroupID(getpgid($0.pid)) }
        .map { Int($0.rawValue) },
      processStartedAt: process.flatMap { RecordedProcess(observing: $0.pid)?.startedAt }
    )
    do {
      try await database.write { database in
        try AppRunRecord.insert { appRun }.execute(database)
      }
    } catch let error as DatabaseError
      where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE
    {
      throw UpError.alreadyRunning(specification.name)
    }
    return appRun
  }

  /// Publishes a recorded run's route, if it has one.
  ///
  /// A route with the requested name that already exists is updated in place rather than
  /// replaced, and remembered so a failed `up` can put it back. The run is pointed at the route
  /// in the same operation that creates it: a published route whose run does not reference it is
  /// one nothing can later prove it owns.
  @OperationRequest
  private func publishRoute(
    _ specification: ApplicationSpecification,
    run appRun: AppRunRecord,
    through admin: MuxAdminClient,
    in database: any DatabaseWriter
  ) async throws -> PublishedRoute {
    guard let exposure = specification.exposure else { return PublishedRoute() }
    var previous: MuxRouteResponse?
    if let requestedRoute = exposure.route {
      previous = try await #run(admin.$routes.retryingWhileMuxStarts())
        .first { $0.route == requestedRoute }
    }
    let route: MuxRouteResponse
    if let previous {
      route = try await admin.update(
        route: previous.route,
        upstream: exposure.upstream.url,
        pathMode: exposure.pathMode
      )
    } else {
      route = try await admin.register(
        MuxRouteRegistrationRequest(
          name: specification.name,
          route: exposure.route,
          upstreamURL: exposure.upstream.description,
          pathMode: exposure.pathMode
        )
      )
    }
    let routeID: UUIDV7? = route.id
    try await database.write { database in
      try AppRunRecord.find(appRun.id)
        .update { $0.routeID = #bind(routeID) }
        .execute(database)
    }
    return PublishedRoute(route: route, previous: previous)
  }

  private func publish(
    _ specification: ApplicationSpecification,
    run appRun: AppRunRecord,
    process: LaunchedProcess?,
    outputTasks: [Task<Void, Never>],
    admin: MuxAdminClient,
    database: any DatabaseWriter
  ) async throws -> RunningApplication {
    let published = try await #run(
      $publishRoute(specification, run: appRun, through: admin, in: database)
    )
    return RunningApplication(
      name: specification.name,
      appRunID: appRun.id,
      process: process,
      route: published.route,
      previousRoute: published.previous,
      outputTasks: outputTasks
    )
  }

  private func requireFree(port: PortNumber, application: String) async throws {
    guard await portProbe.isListening(port: port) else { return }
    let owner = try? await listenerLocator.processes(listeningOn: port).first
    throw UpError.portInUse(application: application, port: port, owner: owner)
  }

  /// Confirms the listener on `port` belongs to the launched process.
  ///
  /// The launched process leads its own group, so anything it forked to hold the socket is in
  /// that group; a direct parent link covers a child that re-parented itself. A scan that cannot
  /// run at all is reported rather than treated as proof either way.
  @OperationRequest
  private func confirmPortOwnership(
    of port: PortNumber,
    by process: LaunchedProcess,
    application: String
  ) async throws {
    let listeners: [ListeningProcess]
    do {
      listeners = try await listenerLocator.processes(listeningOn: port)
    } catch {
      await console.warning(
        "could not confirm which process is listening on port \(port): \(error)"
      )
      return
    }
    let owned = listeners.contains { listener in
      getpgid(listener.pid) == process.pid || listener.parentPID == process.pid
    }
    guard !owned else { return }
    throw UpError.portOwnedElsewhere(
      application: application,
      port: port,
      owner: listeners.first
    )
  }

  private func waitForListener(
    port: PortNumber,
    process: LaunchedProcess?,
    application: String
  ) async throws {
    let timeout = try MillisecondsSetting.applicationStartup.resolve(from: environment)
    let listening: Void? = try await poll(
      $portAnswers(port, of: process, for: application),
      within: timeout
    )
    guard listening != nil else {
      throw UpError.readinessTimedOut(application: application, port: port)
    }
  }

  /// One look at whether the application's declared port has started answering.
  @OperationRequest
  private func portAnswers(
    _ port: PortNumber,
    of process: LaunchedProcess?,
    for application: String
  ) async throws -> PollAttempt<Void> {
    if await portProbe.isListening(port: port) { return .ready(()) }
    if let process, process.hasExited { throw UpError.exitedBeforeReady(application) }
    return .notYet
  }

  private func outputTasksFor(_ process: LaunchedProcess, name: String) -> [Task<Void, Never>] {
    [process.standardOutput, process.standardError]
      .map { stream in
        Task {
          for await line in stream {
            await console.write(
              "[\(name)] \(line.message)",
              toStandardError: line.stream == .standardError
            )
          }
        }
      }
  }

  private func rollback(
    _ running: [RunningApplication],
    admin: MuxAdminClient,
    terminator: ProcessTerminator<ContinuousClock>,
    database: any DatabaseWriter
  ) async {
    for application in running {
      if let process = application.process { await terminator.stopProcessGroup(of: process) }
      for task in application.outputTasks { task.cancel() }
      guard await endRun(application, database: database) else { continue }
      await removeRouteIfCurrent(application, admin: admin, restoringPrevious: true)
    }
  }

  /// Ends the application's run, reporting whether this invocation is the one that ended it.
  ///
  /// Only the winner may touch the route. A route survives a restart in place, so it cannot say
  /// which run owns it; the run record can, and ending it is a compare-and-swap.
  private func endRun(
    _ application: RunningApplication,
    database: any DatabaseWriter
  ) async -> Bool {
    let ended = try? await database.write { database in
      try AppRunRecord.end(application.appRunID, in: database)
    }
    return ended ?? false
  }

  private func removeRouteIfCurrent(
    _ application: RunningApplication,
    admin: MuxAdminClient,
    restoringPrevious: Bool = false
  ) async {
    guard let applied = application.route else { return }
    try? await #run(
      $unpublishRoute(
        applied,
        restoring: restoringPrevious ? application.previousRoute : nil,
        through: admin
      )
    )
  }

  /// Withdraws a route this invocation published, leaving anyone else's in place.
  ///
  /// The route is only touched while it still is the one that was published: a restart between
  /// then and now has replaced it, and its new owner is the one entitled to remove it.
  @OperationRequest
  private func unpublishRoute(
    _ applied: MuxRouteResponse,
    restoring previous: MuxRouteResponse?,
    through admin: MuxAdminClient
  ) async throws {
    guard
      let current = try await #run(admin.$routes.retryingWhileMuxStarts())
        .first(where: { $0.route == applied.route }),
      current.id == applied.id,
      current.upstreamURL == applied.upstreamURL,
      current.pathMode == applied.pathMode
    else { return }
    if let previous, let upstream = URL(string: previous.upstreamURL) {
      _ = try await admin.update(
        route: previous.route,
        upstream: upstream,
        pathMode: previous.pathMode
      )
    } else {
      try await admin.remove(route: applied.route)
    }
  }

  /// Tears the shared runtime down under the runtime lock, so a concurrent `up` cannot be
  /// starting the MUX this decides is unused.
  ///
  /// The lock is taken here rather than around supervision: holding it for the lifetime of the
  /// foreground process would block every other invocation for the project. A failure to acquire
  /// it means another invocation is reconciling and will reach the same decision, so it is
  /// reported and not retried.
  private func stopRuntimeIfUnused(
    _ teardown: ProjectRuntimeTeardown,
    runtime: MuxRunRecord
  ) async {
    do {
      let result = try await FileLock.runtime(forDatabaseAt: databasePath)
        .withLock(.exclusive) {
          await teardown.stopIfUnused(runtime)
        }
      for binding in result.bindings { await console.report(binding) }
      if case .failed(let reason) = result.runtime {
        await console.error("the project runtime was not fully removed: \(reason)")
      }
    } catch {
      await console.warning("could not take the runtime lock to stop the project: \(error)")
    }
  }

  private func printSummary(_ result: UpResult) async {
    await console.write("\(result.projectName)  \(result.baseURL.absoluteString)")
    for application in result.applications {
      if let url = application.publicURL {
        await console.write("  \(application.name)  \(url.absoluteString)")
      } else if let pid = application.pid {
        await console.write("  \(application.name)  pid \(pid) (not exposed)")
      }
    }
  }
}

/// A managed application's process and the tasks draining its output.
private struct LaunchedApplication: Sendable {
  let process: LaunchedProcess
  let outputTasks: [Task<Void, Never>]
}

/// A route this invocation published, and whatever it replaced.
struct PublishedRoute: Sendable {
  var route: MuxRouteResponse?
  var previous: MuxRouteResponse?
}

private struct RunningApplication: Sendable {
  let name: String
  let appRunID: UUIDV7
  let process: LaunchedProcess?
  let route: MuxRouteResponse?
  let previousRoute: MuxRouteResponse?
  let outputTasks: [Task<Void, Never>]

  func started(baseURL: URL) -> StartedApplication {
    StartedApplication(
      name: name,
      route: route?.route,
      publicURL: route.flatMap { URL(string: $0.publicPath, relativeTo: baseURL) },
      pid: process?.pid
    )
  }
}

private final class SignalSupervisor: @unchecked Sendable {
  private let onSignal: @Sendable () -> Void
  private let queue = DispatchQueue(label: "com.tailreg.cli.signals")
  private var sources: [DispatchSourceSignal] = []

  init(onSignal: @escaping @Sendable () -> Void) {
    self.onSignal = onSignal
  }

  func start() {
    for signalNumber in [SIGINT, SIGTERM] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
      source.setEventHandler { [onSignal] in onSignal() }
      source.resume()
      sources.append(source)
    }
  }

  func stop() {
    for source in sources { source.cancel() }
    sources.removeAll()
    signal(SIGINT, SIG_DFL)
    signal(SIGTERM, SIG_DFL)
  }
}

enum UpError: Error, CustomStringConvertible, Sendable {
  case configurationRequired
  case alreadyRunning(String)
  case exitedBeforeReady(String)
  case readinessTimedOut(application: String, port: PortNumber)
  case portInUse(application: String, port: PortNumber, owner: ListeningProcess?)
  case portOwnedElsewhere(application: String, port: PortNumber, owner: ListeningProcess?)

  var description: String {
    switch self {
    case .portInUse(let app, let port, let owner):
      "port \(port) for application '\(app)' is already in use\(Self.describe(owner))"
    case .portOwnedElsewhere(let app, let port, let owner):
      "application '\(app)' did not bind port \(port); it is held\(Self.describe(owner))"
    case .configurationRequired: "no tailreg.toml was found for this project"
    case .alreadyRunning(let app): "application '\(app)' is already running in this project"
    case .exitedBeforeReady(let app): "application '\(app)' exited before becoming ready"
    case .readinessTimedOut(let app, let port):
      "timed out waiting for application '\(app)' on port \(port)"
    }
  }

  private static func describe(_ owner: ListeningProcess?) -> String {
    guard let owner else { return " by another process" }
    return " by \(owner.name ?? "another process") (pid \(owner.pid))"
  }
}
