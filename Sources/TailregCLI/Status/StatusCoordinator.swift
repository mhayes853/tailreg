import Foundation
import SQLiteData
import TailregCore
import TailregMultiplexer
import UUIDV7

struct StatusRequest: Sendable {
  var projectPath: String?
  var allProjects = false
}

/// Reads what a project is doing, without changing any of it.
///
/// Three things this deliberately does not do, each of which the other commands do:
///
/// - It does not take the runtime lock. `down` holds that lock across its whole reconciliation
///   and `FileLock` polls for ten seconds before giving up, so a locking `status` would stall
///   exactly when the runtime is busy or wedged — which is when it is worth running.
/// - It does not reclaim abandoned runs. `up` and `down` end live records whose process is gone;
///   doing that here would erase the discrepancy the report exists to show. The same verdict is
///   computed and reported instead.
/// - It does not ask Tailscale anything. `TailscaleBinder.bindings()` shells out twice and
///   reconciles binding records as it goes, which would make an observing command both a writer
///   and a hostage to the daemon being up. The recorded binding is read directly instead, and a
///   binding that should exist but does not is reported rather than repaired.
struct StatusCoordinator: Sendable {
  private let databasePath: String
  private let currentDirectory: URL
  private let portProbe: any PortProbe
  private let muxIsReady: @Sendable (Int) async -> Bool

  init(
    databasePath: String = defaultTailregDatabasePath(),
    currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    portProbe: any PortProbe = SystemPortProbe(),
    muxIsReady: @escaping @Sendable (Int) async -> Bool = { port in
      await MuxAdminClient(port: port).isReady()
    }
  ) {
    self.databasePath = databasePath
    self.currentDirectory = currentDirectory
    self.portProbe = portProbe
    self.muxIsReady = muxIsReady
  }

  func run(_ request: StatusRequest) async throws -> StatusReport {
    let database = try openTailregDatabase(path: databasePath)
    guard request.allProjects else {
      let project = try await ResolvedProject.inspect(
        database: database,
        explicitPath: request.projectPath,
        currentDirectory: currentDirectory
      )
      return StatusReport(projects: [try await status(of: project, database: database)])
    }

    let records = try await database.read { database in
      try ProjectRecord.all.order { ($0.name, $0.rootPath) }.fetchAll(database)
    }
    var projects: [ProjectStatus] = []
    for record in records {
      projects.append(
        try await status(of: await inspect(record, database: database), database: database)
      )
    }
    return StatusReport(projects: projects)
  }

  /// Reads a known project's directory, tolerating one that has since been moved or deleted.
  ///
  /// `--all` reports on records, and a record outlives the directory that produced it. Losing
  /// the configuration costs the report its desired-state half, which is worth far less than
  /// refusing to report on the rest of the machine.
  private func inspect(
    _ record: ProjectRecord,
    database: any DatabaseWriter
  ) async -> InspectedProject {
    let root = URL(fileURLWithPath: record.rootPath)
    let inspected = try? await ResolvedProject.inspect(
      database: database,
      explicitPath: record.rootPath,
      currentDirectory: root
    )
    guard let inspected, inspected.record?.id == record.id else {
      return InspectedProject(record: record, root: root, specification: nil)
    }
    return inspected
  }

  private func status(
    of project: InspectedProject,
    database: any DatabaseWriter
  ) async throws -> ProjectStatus {
    guard let record = project.record else {
      // Configured but never brought up. The applications are still worth listing: `status` in a
      // project that is down should describe the project, not print nothing.
      return ProjectStatus(
        name: project.name,
        root: project.root.path,
        mux: MuxStatus(state: .notRunning),
        applications: stoppedApplications(of: project),
        problems: []
      )
    }

    // Three reads that need nothing from each other, against a pool that can serve them at once.
    async let runtimeRead = database.read { database in
      try MuxRunRecord.live(for: record.id).fetchOne(database)
    }
    async let routesRead = database.read { database in
      try MuxRouteRecord.live(muxID: record.muxID).fetchAll(database)
    }
    async let runsRead = database.read { database in
      try AppRunRecord.live(for: record.id).fetchAll(database)
    }
    let (runtime, routes, runs) = try await (runtimeRead, routesRead, runsRead)

    let binding = try await liveBinding(for: runtime, database: database)
    let baseURL = baseURL(for: runtime, binding: binding)
    // The two halves that leave the process — the MUX admin API and the attached upstreams —
    // and neither needs the other's answer. Overlapping them keeps one unreachable thing from
    // adding its timeout to everything reported after it.
    async let muxRead = muxStatus(of: runtime)
    async let applicationsRead = applicationStatuses(
      of: project,
      runs: runs,
      routes: routes,
      baseURL: baseURL
    )
    let (mux, applications) = await (muxRead, applicationsRead)

    return ProjectStatus(
      name: project.name,
      root: project.root.path,
      url: baseURL,
      exposure: runtime?.exposure,
      mux: mux,
      applications: applications,
      problems: problems(
        runtime: runtime,
        binding: binding,
        mux: mux,
        applications: applications,
        routes: routes,
        runs: runs,
        isConfigured: project.specification != nil
      )
    )
  }

  // MARK: - Runtime

  /// Reads the MUX's state, asking the admin API before checking the process.
  ///
  /// An answering admin API is the stronger evidence of the two: it proves a MUX is serving on
  /// the recorded port, whereas a matching process only proves one was started.
  private func muxStatus(of runtime: MuxRunRecord?) async -> MuxStatus {
    guard let runtime else { return MuxStatus(state: .notRunning) }
    let state: MuxStatus.State
    if await muxIsReady(runtime.adminPort) {
      state = .running
    } else if runtime.hasMatchingProcess {
      state = .unreachable
    } else {
      state = .stale
    }
    return MuxStatus(
      state: state,
      pid: runtime.pid,
      ingressPort: runtime.ingressPort,
      adminPort: runtime.adminPort,
      startedAt: runtime.createdAt
    )
  }

  private func baseURL(for runtime: MuxRunRecord?, binding: TailscaleBindingRecord?) -> URL? {
    guard let runtime else { return nil }
    switch runtime.exposure {
    case .local: return URL(string: "http://127.0.0.1:\(runtime.ingressPort)/")
    case .tailnet: return binding?.url
    }
  }

  // MARK: - Applications

  private func stoppedApplications(of project: InspectedProject) -> [ApplicationStatus] {
    (project.specification?.applications ?? [])
      .sorted { $0.name < $1.name }
      .map {
        ApplicationStatus(
          name: $0.name,
          state: .stopped,
          configured: true,
          isExposed: $0.isExposed
        )
      }
  }

  private func applicationStatuses(
    of project: InspectedProject,
    runs: [AppRunRecord],
    routes: [MuxRouteRecord],
    baseURL: URL?
  ) async -> [ApplicationStatus] {
    let configured = Dictionary(
      (project.specification?.applications ?? []).map { ($0.name, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    // One live run per application is a unique index, so this cannot collapse two live runs.
    let live = Dictionary(runs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    var statuses: [ApplicationStatus] = []
    for name in Set(configured.keys).union(live.keys).sorted() {
      let specification = configured[name]
      guard let run = live[name] else {
        statuses.append(
          ApplicationStatus(
            name: name,
            state: .stopped,
            configured: true,
            isExposed: specification?.isExposed
          )
        )
        continue
      }
      let route = run.routeID.flatMap { id in routes.first { $0.id == id } }
      statuses.append(
        ApplicationStatus(
          name: name,
          state: await state(of: run, route: route),
          ownership: run.ownership,
          configured: specification != nil,
          isExposed: specification?.isExposed,
          pid: run.pid,
          processGroupID: run.processGroupID,
          startedAt: run.createdAt,
          route: route.map { routeStatus(of: $0, baseURL: baseURL) }
        )
      )
    }
    return statuses
  }

  /// Decides whether one recorded run is still real.
  ///
  /// The two ownerships have nothing in common here. A managed run is judged on process identity,
  /// which is what `down` signals on. An attached run has no process by construction — the schema
  /// forbids a PID on one — so the only evidence available is whether its upstream still answers.
  private func state(
    of run: AppRunRecord,
    route: MuxRouteRecord?
  ) async -> ApplicationStatus.State {
    switch run.ownership {
    case .managed:
      guard run.processStartedAt != nil else { return .unverified }
      return run.hasMatchingProcess ? .running : .stale
    case .attached:
      guard let upstream = route.flatMap({ URL(string: $0.upstreamURL) }),
        let host = upstream.host,
        let port = upstream.listenerPort
      else { return .unverified }
      return await portProbe.isListening(host: host, port: port) ? .running : .unreachable
    }
  }

  private func routeStatus(of route: MuxRouteRecord, baseURL: URL?) -> RouteStatus {
    let path = MuxPathPolicy().publicPath(route: route.route)
    return RouteStatus(
      id: route.id,
      path: path,
      // Resolved to an absolute URL: a relative one would encode as its two halves in JSON.
      url: baseURL.flatMap { URL(string: path, relativeTo: $0) }
        .flatMap { URL(string: $0.absoluteString) },
      upstreamURL: route.upstreamURL,
      pathMode: route.pathMode
    )
  }

  // MARK: - Problems

  private func problems(
    runtime: MuxRunRecord?,
    binding: TailscaleBindingRecord?,
    mux: MuxStatus,
    applications: [ApplicationStatus],
    routes: [MuxRouteRecord],
    runs: [AppRunRecord],
    isConfigured: Bool
  ) -> [StatusProblem] {
    var problems: [StatusProblem] = []

    if let runtime, runtime.exposure == .tailnet, binding == nil {
      problems.append(
        StatusProblem(
          subject: "binding",
          kind: .missing,
          detail: "no live binding for ingress port \(runtime.ingressPort)"
        )
      )
    }

    switch mux.state {
    case .unreachable:
      problems.append(
        StatusProblem(
          subject: "mux",
          kind: .unreachable,
          detail:
            "alive as pid \(mux.pid ?? 0), not answering on admin port \(mux.adminPort ?? 0)"
        )
      )
    case .stale:
      problems.append(
        StatusProblem(
          subject: "mux",
          kind: .staleProcess,
          detail: "recorded as running, but pid \(mux.pid ?? 0) is gone"
        )
      )
    case .running, .notRunning:
      break
    }

    for application in applications {
      switch application.state {
      case .stale:
        problems.append(
          StatusProblem(
            subject: application.name,
            kind: .staleProcess,
            detail: "pid \(application.pid ?? 0) is not the process that started it"
          )
        )
      case .unreachable:
        problems.append(
          StatusProblem(
            subject: application.name,
            kind: .notListening,
            detail:
              "attached upstream \(authority(of: application.route)) is not listening"
          )
        )
      case .running, .unverified, .stopped:
        break
      }

      // Only meaningful against a configuration. Without a `tailreg.toml` every application is
      // ad hoc, and reporting each one as unconfigured would be noise rather than a finding.
      if isConfigured, !application.configured, application.state != .stopped {
        problems.append(
          StatusProblem(
            subject: application.name,
            kind: .notConfigured,
            detail: application.route == nil
              ? "is running but is not in tailreg.toml"
              : "has a live route but is not in tailreg.toml"
          )
        )
      }
    }

    // A route is published after its run is recorded and removed before that run is ended, so a
    // route with no owning run is the trace of an invocation that died between the two.
    let owned = Set(runs.compactMap(\.routeID))
    for route in routes where !owned.contains(route.id) {
      problems.append(
        StatusProblem(
          subject: route.route,
          kind: .orphanedRoute,
          detail: "served with no application run to own it"
        )
      )
    }
    return problems
  }

  // MARK: - Queries


  private func liveBinding(
    for runtime: MuxRunRecord?,
    database: any DatabaseWriter
  ) async throws -> TailscaleBindingRecord? {
    guard let runtime, runtime.exposure == .tailnet else { return nil }
    let ingressPort = runtime.ingressPort
    return try await database.read { database in
      try TailscaleBindingRecord
        .where { $0.localPort.eq(ingressPort) && $0.endedAt.is(nil) }
        .order { $0.createdAt.desc() }
        .fetchOne(database)
    }
  }

  // MARK: - Upstreams

  private func authority(of route: RouteStatus?) -> String {
    guard let upstream = route.flatMap({ URL(string: $0.upstreamURL) }),
      let host = upstream.host,
      let port = upstream.listenerPort
    else { return route?.upstreamURL ?? "the upstream" }
    return "\(host):\(port)"
  }
}
