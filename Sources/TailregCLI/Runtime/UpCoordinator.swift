import Foundation
import SQLiteData
import TailregCore
import TailregMultiplexer
import UUIDV7

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct UpRequest: Sendable {
  var projectPath: String?
  var applicationNames: [String] = []
  var adHocApplication: String?
  var route: String?
  var port: PortNumber?
  var attachURL: URL?
  var command: [String] = []
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
  let route: String?
  let publicURL: URL?
  let pid: Int32?
}

struct UpCoordinator: Sendable {
  private let databasePath: String
  private let executableURL: URL
  private let environment: [String: String]
  private let currentDirectory: URL
  private let console = Console()

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

  func run(
    _ request: UpRequest,
    onReady: @Sendable (UpResult) async -> Void = { _ in }
  ) async throws -> UpResult {
    let database = try openTailregDatabase(path: databasePath)
    let terminator = try ProcessTerminator(environment: environment)
    let project = try await ResolvedProject.resolve(
      database: database,
      explicitPath: request.projectPath,
      currentDirectory: currentDirectory
    )
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
    let (runtime, muxWasStarted) = try await muxController.ensureRunning(
      for: project.record,
      exposure: exposure
    )
    if request.localOnly, runtime.exposure == .tailnet {
      await console.warning(
        "this project is already published on the tailnet; --local-only leaves that binding in place"
      )
    }
    let endpointController = TailnetEndpointController(
      databasePath: databasePath,
      localOnly: request.localOnly,
      requestedPort: request.tailnetPort,
      environment: environment
    )
    let baseURL: URL
    do {
      baseURL = try await endpointController.ensure(ingressPort: runtime.ingressPort)
    } catch {
      if muxWasStarted { try? await muxController.stop(runtime) }
      throw error
    }

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
              try await start(
                application,
                baseURL: baseURL,
                admin: admin,
                terminator: terminator,
                database: database,
                projectID: project.record.id
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
      applications: running.map {
        StartedApplication(
          name: $0.name,
          route: $0.route?.route,
          publicURL: $0.route.flatMap { URL(string: $0.publicPath, relativeTo: baseURL) },
          pid: $0.process?.pid
        )
      }
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
    if let name = request.adHocApplication {
      let command: ProcessCommand? =
        request.command.isEmpty
        ? nil
        : {
          ProcessCommand(
            executable: request.command[0],
            arguments: Array(request.command.dropFirst()),
            workingDirectory: project.root
          )
        }()
      let application = try ApplicationSpecification(
        name: name,
        route: request.route,
        port: request.port,
        attachURL: request.attachURL,
        command: command
      )
      return [[application]]
    }
    guard request.command.isEmpty else { throw UpError.commandRequiresApplication }
    guard let specification = project.specification else {
      throw UpError.configurationRequired
    }
    return try specification.selected(request.applicationNames)
  }

  private func start(
    _ specification: ApplicationSpecification,
    baseURL: URL,
    admin: MuxAdminClient,
    terminator: ProcessTerminator<ContinuousClock>,
    database: any DatabaseWriter,
    projectID: UUIDV7
  ) async throws -> RunningApplication {
    var process: LaunchedProcess?
    var outputTasks: [Task<Void, Never>] = []
    if var command = specification.command {
      command.environment = environment.merging(command.environment) { _, configured in configured }
      command.environment["TAILREG_PROJECT_URL"] = baseURL.absoluteString
      if let route = specification.route {
        command.environment["TAILREG_APP_PATH"] = "/\(route)/"
      }
      if let port = specification.port {
        command.environment["TAILREG_PORT"] = port.description
      }
      let supervisedCommand = ProcessCommand(
        executable: executableURL.path,
        arguments: [SupervisedCommand.marker, command.executable] + command.arguments,
        workingDirectory: command.workingDirectory,
        environment: command.environment
      )
      let launched = try SystemProcessLauncher().launch(supervisedCommand)
      process = launched
      outputTasks = outputTasksFor(launched, name: specification.name)
    }

    do {
      if let port = specification.listenerPort {
        try await waitForListener(port: port, process: process, application: specification.name)
      }

      // Recorded before the route is published: a run without a route can be reconciled later,
      // whereas a published route with no owning run has nothing to identify who may remove it.
      let appRun = AppRunRecord(
        projectID: projectID,
        name: specification.name,
        ownership: process == nil ? .attached : .managed,
        pid: process.map { Int($0.pid) },
        processGroupID: process.flatMap { ProcessGroupID(getpgid($0.pid)) }
          .map { Int($0.rawValue) },
        processStartedAt: process.flatMap { processStartTime(of: $0.pid) }
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

      do {
        var running = try await publish(
          specification,
          run: appRun,
          process: process,
          admin: admin,
          database: database
        )
        running.outputTasks = outputTasks
        return running
      } catch {
        // The run was recorded but never published. An attached run has no process for
        // `reclaimAbandoned` to disprove, so it would otherwise block this application until the
        // next `down`.
        _ = try? await database.write { database in try AppRunRecord.end(appRun.id, in: database) }
        throw error
      }
    } catch {
      if let process { await terminator.stopProcessGroup(of: process) }
      for task in outputTasks { task.cancel() }
      throw error
    }
  }

  /// Publishes a recorded run's route, if it has one.
  ///
  /// A route with the requested name that already exists is updated in place rather than
  /// replaced, and remembered so a failed `up` can put it back.
  private func publish(
    _ specification: ApplicationSpecification,
    run appRun: AppRunRecord,
    process: LaunchedProcess?,
    admin: MuxAdminClient,
    database: any DatabaseWriter
  ) async throws -> RunningApplication {
    let route: MuxRouteResponse?
    let previousRoute: MuxRouteResponse?
    if specification.isExposed {
      let upstream = specification.upstreamURL
      let existing: MuxRouteResponse?
      if let requestedRoute = specification.route {
        existing = try await admin.routes().first { $0.route == requestedRoute }
      } else {
        existing = nil
      }
      if let existing {
        route = try await admin.update(
          route: existing.route,
          upstream: upstream,
          pathMode: specification.pathMode
        )
        previousRoute = existing
      } else {
        route = try await admin.register(
          MuxRouteRegistrationRequest(
            name: specification.name,
            route: specification.route,
            upstreamURL: upstream.absoluteString,
            pathMode: specification.pathMode
          )
        )
        previousRoute = nil
      }
    } else {
      route = nil
      previousRoute = nil
    }
    if let route {
      let routeID: UUIDV7? = route.id
      try await database.write { database in
        try AppRunRecord.find(appRun.id)
          .update { $0.routeID = #bind(routeID) }
          .execute(database)
      }
    }

    return RunningApplication(
      name: specification.name,
      appRunID: appRun.id,
      process: process,
      route: route,
      previousRoute: previousRoute,
      outputTasks: []
    )
  }

  private func waitForListener(
    port: PortNumber,
    process: LaunchedProcess?,
    application: String
  ) async throws {
    let timeout = try MillisecondsSetting.applicationStartup.resolve(from: environment)
    let probe = SystemPortProbe()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await probe.isListening(port: port) { return }
      if let process, process.hasExited { throw UpError.exitedBeforeReady(application) }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw UpError.readinessTimedOut(application: application, port: port)
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
    guard let applied = application.route,
      let current = (try? await admin.routes())?.first(where: { $0.route == applied.route }),
      current.id == applied.id,
      current.upstreamURL == applied.upstreamURL,
      current.pathMode == applied.pathMode
    else { return }
    if restoringPrevious, let previous = application.previousRoute,
      let upstream = URL(string: previous.upstreamURL)
    {
      _ = try? await admin.update(
        route: previous.route,
        upstream: upstream,
        pathMode: previous.pathMode
      )
    } else {
      try? await admin.remove(route: applied.route)
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
    let lock = FileLock(path: databasePath + ".runtime.lock")
    do {
      let outcome = try await lock.withLock(.exclusive) {
        await teardown.stopIfUnused(runtime)
      }
      if case .failed(let reason) = outcome {
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

private struct RunningApplication: Sendable {
  let name: String
  let appRunID: UUIDV7
  let process: LaunchedProcess?
  let route: MuxRouteResponse?
  let previousRoute: MuxRouteResponse?
  var outputTasks: [Task<Void, Never>]
}

actor Console {
  func write(_ message: String, toStandardError: Bool = false) {
    let data = Data((message + "\n").utf8)
    try? (toStandardError ? FileHandle.standardError : FileHandle.standardOutput)
      .write(contentsOf: data)
  }

  /// Something worth tracing that is not a failure: the work was done, but not as intended.
  func warning(_ message: String) {
    write("warning: \(message)", toStandardError: true)
  }

  /// Something that leaves the system in a state the caller did not ask for.
  func error(_ message: String) {
    write("error: \(message)", toStandardError: true)
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
  case commandRequiresApplication
  case alreadyRunning(String)
  case exitedBeforeReady(String)
  case readinessTimedOut(application: String, port: PortNumber)

  var description: String {
    switch self {
    case .configurationRequired: "no tailreg.toml was found for this project"
    case .commandRequiresApplication: "an ad hoc command requires --app"
    case .alreadyRunning(let app): "application '\(app)' is already running in this project"
    case .exitedBeforeReady(let app): "application '\(app)' exited before becoming ready"
    case .readinessTimedOut(let app, let port):
      "timed out waiting for application '\(app)' on port \(port)"
    }
  }
}
