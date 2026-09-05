import Foundation
import SQLiteData
import TailregCore
import Testing
import UUIDV7

@testable import TailregCLI

/// Root bindings are reference-counted by the live runs that hold them. These drive the teardown
/// with a recording endpoint controller, since the real one needs a Tailscale daemon.
@Suite(.timeLimit(.minutes(1)))
struct `Project runtime teardown tests` {
  @Test
  func `A binding no run holds is removed while a held one is kept and its holders named`()
    async throws
  {
    let context = try Context()
    defer { context.cleanUp() }
    let runtime = try context.insertRuntime()
    let held = try context.insertBinding(tailnetPort: 443)
    let unheld = try context.insertBinding(tailnetPort: 8443)
    try context.insertRun("api", holding: held)
    try context.insertRun("web", holding: held)

    let result = await context.teardown(routes: 2).stopIfUnused(runtime)

    #expect(result.runtime == .stillInUse(routes: 2))
    #expect(result.bindings == [.retained(held, holders: ["api", "web"]), .removed(unheld)])
    #expect(await context.endpoints.removed == [unheld])
  }

  @Test
  func `Unbinding all removes held bindings and still names their holders`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let runtime = try context.insertRuntime()
    let held = try context.insertBinding(tailnetPort: 443)
    try context.insertRun("api", holding: held)

    let result = await context.teardown(routes: 1).stopIfUnused(runtime, unbindingAll: true)

    #expect(result.runtime == .stillInUse(routes: 1))
    #expect(result.bindings == [.forced(held, holders: ["api"])])
    #expect(await context.endpoints.removed == [held])
  }

  /// With the MUX going, a binding would point at nothing, so every one goes with it.
  @Test
  func `The last route takes every binding and the MUX record with it`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let runtime = try context.insertRuntime()
    let binding = try context.insertBinding(tailnetPort: 443)

    let result = await context.teardown(routes: 0).stopIfUnused(runtime)

    #expect(result.runtime == .stopped)
    #expect(result.bindings == [.removed(binding)])
    let live = try await context.database.read { db in
      try MuxRunRecord.live(for: runtime.projectID).fetchOne(db)
    }
    #expect(live == nil)
  }

  @Test
  func `A binding that cannot be removed fails the teardown`() async throws {
    let context = try Context()
    defer { context.cleanUp() }
    let runtime = try context.insertRuntime()
    let binding = try context.insertBinding(tailnetPort: 443)
    await context.endpoints.fail()

    let result = await context.teardown(routes: 0).stopIfUnused(runtime)

    #expect(result.bindings.count == 1)
    #expect(result.bindings.first?.isFailure == true)
    if case .failed = result.runtime {
    } else {
      Issue.record("expected a failed teardown, got \(result.runtime)")
    }
    _ = binding
  }

  private actor RecordingEndpoints: TailnetEndpointRemoving {
    private(set) var removed: [TailscaleBindingRecord] = []
    private var failing = false

    func fail() { failing = true }

    func remove(_ binding: TailscaleBindingRecord) async throws {
      if failing { throw RemovalFailure() }
      removed.append(binding)
    }

    struct RemovalFailure: Error {}
  }

  private struct Context {
    let root: URL
    let databasePath: String
    let database: any DatabaseWriter
    let project: ProjectRecord
    let endpoints = RecordingEndpoints()

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailreg-teardown-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      databasePath = root.appendingPathComponent("tailreg.sqlite").path
      database = try openTailregDatabase(path: databasePath)
      project = ProjectRecord(rootPath: root.path, name: "demo")
      let project = self.project
      try database.write { db in try ProjectRecord.insert { project }.execute(db) }
    }

    func teardown(routes: Int) -> ProjectRuntimeTeardown {
      ProjectRuntimeTeardown(
        liveRouteCount: { routes },
        muxController: MuxProcessController(
          database: database,
          databasePath: databasePath,
          executableURL: URL(fileURLWithPath: "/bin/false"),
          terminator: ProcessTerminator()
        ),
        endpointController: endpoints
      )
    }

    /// A runtime whose process cannot be verified, so stopping it ends the record without
    /// signalling anything.
    func insertRuntime() throws -> MuxRunRecord {
      let runtime = MuxRunRecord(
        projectID: project.id,
        pid: 1,
        ingressPort: 39_428,
        adminPort: 39_429,
        exposure: .tailnet
      )
      try database.write { db in try MuxRunRecord.insert { runtime }.execute(db) }
      return runtime
    }

    func insertBinding(tailnetPort: Int) throws -> TailscaleBindingRecord {
      let binding = TailscaleBindingRecord(
        hostname: "demo.tail1234.ts.net",
        localPort: 39_428,
        tailnetPort: tailnetPort,
        proto: .https,
        mountPath: "/",
        status: .active,
        // Whole seconds, so the record read back compares equal to the one inserted.
        createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(tailnetPort))
      )
      try database.write { db in try TailscaleBindingRecord.insert { binding }.execute(db) }
      return binding
    }

    func insertRun(_ name: String, holding binding: TailscaleBindingRecord) throws {
      let run = AppRunRecord(
        projectID: project.id,
        name: name,
        ownership: .attached,
        bindingID: binding.id
      )
      try database.write { db in try AppRunRecord.insert { run }.execute(db) }
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }
  }
}
