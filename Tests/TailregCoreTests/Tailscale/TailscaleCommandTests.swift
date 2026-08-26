import Foundation
import TailregCore
import Testing

@Suite
struct `Tailscale command failure tests` {
  private func makeBinder(
    _ runner: StubProcessRunner,
    temp: TempDirectory,
    listening: Set<Int> = [3000]
  ) -> TailscaleBinder {
    TailscaleBinder(
      binaryPath: "/usr/bin/tailscale",
      runner: runner,
      portProbe: StubPortProbe(listening: listening),
      registryPath: temp.path("bindings.json")
    )
  }

  private func runnerReadyToServe() -> StubProcessRunner {
    let runner = StubProcessRunner()
    runner.stub(["status", "--json"], stdout: Fixtures.nodeStatus)
    runner.stub(["serve", "status", "--json"], stdout: "{}")
    return runner
  }

  @Test
  func `Maps Missing Operator Rights To A Specific Error`() async throws {
    let temp = try TempDirectory()
    let runner = runnerReadyToServe()
    runner.stub(
      ["serve", "--bg"],
      stderr: "Access denied: serve config denied; try: tailscale set --operator=$USER",
      exitCode: 1
    )

    await #expect(throws: TailscaleError.operatorPermissionDenied) {
      try await makeBinder(runner, temp: temp).bind(localPort: 3000)
    }
  }

  @Test
  func `Maps A Stopped Daemon To A Specific Error`() async throws {
    let temp = try TempDirectory()
    let runner = runnerReadyToServe()
    runner.stub(["serve", "--bg"], stderr: "Tailscale is stopped.", exitCode: 1)

    await #expect(throws: TailscaleError.daemonNotRunning(state: "Tailscale is stopped.")) {
      try await makeBinder(runner, temp: temp).bind(localPort: 3000)
    }
  }

  @Test
  func `Preserves Argv And Stderr On An Unrecognised Failure`() async throws {
    let temp = try TempDirectory()
    let runner = runnerReadyToServe()
    runner.stub(["serve", "--bg"], stderr: "something unexpected", exitCode: 7)

    await #expect(
      throws: TailscaleError.commandFailed(
        argv: ["serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:3000"],
        exitCode: 7,
        standardError: "something unexpected"
      )
    ) {
      try await makeBinder(runner, temp: temp).bind(localPort: 3000)
    }
  }

  @Test
  func `Reads A Binary That Will Not Launch As Not Installed`() async throws {
    let temp = try TempDirectory()
    let runner = StubProcessRunner()
    runner.failToLaunch()

    await #expect(throws: TailscaleError.notInstalled) {
      try await makeBinder(runner, temp: temp).bindings()
    }
  }

  @Test
  func `Prefers Status Output Over A Non Zero Exit Code`() async throws {
    let temp = try TempDirectory()
    let runner = StubProcessRunner()
    runner.stub(["status", "--json"], stdout: Fixtures.stoppedNodeStatus, exitCode: 1)

    await #expect(throws: TailscaleError.daemonNotRunning(state: "Stopped")) {
      try await makeBinder(runner, temp: temp).bindings()
    }
  }
}
