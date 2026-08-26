import Foundation
import TailregCore
import Testing

@Suite
struct `TailscaleCLI tests` {
  private func makeCLI(_ runner: StubProcessRunner) -> TailscaleCLI {
    TailscaleCLI(binaryPath: "/usr/bin/tailscale", runner: runner)
  }

  @Test
  func `Serves In The Background Without Prompting`() async throws {
    let runner = StubProcessRunner()

    try await makeCLI(runner)
      .serve(
        localPort: 3000,
        tailnetPort: 443,
        proto: .https,
        mountPath: "/",
        funnel: false
      )

    #expect(
      runner.argvHistory == [
        ["serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:3000"]
      ]
    )
  }

  @Test
  func `Adds Set Path Only For A Non Root Mount Path`() async throws {
    let runner = StubProcessRunner()

    try await makeCLI(runner)
      .serve(
        localPort: 3000,
        tailnetPort: 8443,
        proto: .https,
        mountPath: "/api",
        funnel: false
      )

    #expect(
      runner.argvHistory == [
        ["serve", "--bg", "--yes", "--https=8443", "--set-path=/api", "http://127.0.0.1:3000"]
      ]
    )
  }

  @Test
  func `Routes Funnel Through Its Own Subcommand`() async throws {
    let runner = StubProcessRunner()

    try await makeCLI(runner)
      .serve(
        localPort: 3000,
        tailnetPort: 443,
        proto: .https,
        mountPath: "/",
        funnel: true
      )

    #expect(runner.argvHistory.first?.first == "funnel")
  }

  @Test
  func `Removes A Single Handler Rather Than A Whole Port`() async throws {
    let runner = StubProcessRunner()

    try await makeCLI(runner).serveOff(tailnetPort: 8443, proto: .https, mountPath: "/api")

    #expect(runner.argvHistory == [["serve", "--https=8443", "--set-path=/api", "off"]])
  }

  @Test
  func `Strips The Trailing Dot From The Reported DNS Name`() async throws {
    let runner = StubProcessRunner()
    runner.stub(["status"], stdout: Fixtures.nodeStatus)

    let status = try await makeCLI(runner).status()

    #expect(status.dnsName == "omarchy.tailc6bff1.ts.net")
  }

  @Test
  func `Prefers Status Output Over A Non Zero Exit Code`() async throws {
    let runner = StubProcessRunner()
    runner.stub(["status"], stdout: Fixtures.stoppedNodeStatus, exitCode: 1)

    let status = try await makeCLI(runner).status()

    #expect(status.backendState == "Stopped")
    #expect(status.isRunning == false)
  }

  @Test
  func `Reads The Version From The First Line Only`() async throws {
    let runner = StubProcessRunner()
    runner.stub(
      ["version"],
      stdout: "1.102.3\n  tailscale commit: 9329c36\n  go version: go1.26.6"
    )

    #expect(try await makeCLI(runner).version() == "1.102.3")
  }

  @Test
  func `Maps Missing Operator Rights To A Specific Error`() async {
    let runner = StubProcessRunner()
    runner.stub(
      ["serve"],
      stderr: "Access denied: serve config denied; try: tailscale set --operator=$USER",
      exitCode: 1
    )

    await #expect(throws: TailscaleError.operatorPermissionDenied) {
      try await makeCLI(runner)
        .serve(localPort: 1, tailnetPort: 443, proto: .https, mountPath: "/", funnel: false)
    }
  }

  @Test
  func `Maps A Stopped Daemon To A Specific Error`() async {
    let runner = StubProcessRunner()
    runner.stub(["serve"], stderr: "Tailscale is stopped.", exitCode: 1)

    await #expect(throws: TailscaleError.daemonNotRunning(state: "Tailscale is stopped.")) {
      try await makeCLI(runner)
        .serve(localPort: 1, tailnetPort: 443, proto: .https, mountPath: "/", funnel: false)
    }
  }

  @Test
  func `Preserves Argv And Stderr On An Unrecognised Failure`() async {
    let runner = StubProcessRunner()
    runner.stub(["serve"], stderr: "something unexpected", exitCode: 7)

    await #expect(
      throws: TailscaleError.commandFailed(
        argv: ["serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:1"],
        exitCode: 7,
        standardError: "something unexpected"
      )
    ) {
      try await makeCLI(runner)
        .serve(localPort: 1, tailnetPort: 443, proto: .https, mountPath: "/", funnel: false)
    }
  }

  @Test
  func `Reads A Binary That Will Not Launch As Not Installed`() async {
    let runner = StubProcessRunner()
    runner.failToLaunch()

    await #expect(throws: TailscaleError.notInstalled) {
      try await makeCLI(runner).version()
    }
  }
}
