import Foundation
import TailregCore
import Testing

@Suite
struct `SystemProcessRunner tests` {
  private let runner = SystemProcessRunner()

  @Test
  func `Separates Standard Output From Standard Error`() async throws {
    let result = try await runner.run(
      executable: "/bin/sh",
      arguments: ["-c", "echo out; echo err >&2"]
    )

    #expect(result.standardOutputText == "out")
    #expect(result.standardErrorText == "err")
  }

  @Test
  func `Reports A Non Zero Exit Without Throwing`() async throws {
    let result = try await runner.run(executable: "/bin/sh", arguments: ["-c", "exit 3"])

    #expect(result.exitCode == 3)
  }

  @Test
  func `Throws When The Executable Cannot Be Launched`() async {
    await #expect(throws: ProcessRunnerError.self) {
      try await runner.run(executable: "/nonexistent/tailscale", arguments: [])
    }
  }

  @Test
  func `Collects Output Larger Than The Pipe Buffer`() async throws {
    let result = try await runner.run(
      executable: "/bin/sh",
      arguments: ["-c", "head -c 2000000 /dev/zero"]
    )

    #expect(result.standardOutput.count == 2_000_000)
  }

  @Test
  func `Collects Both Pipes When Each Exceeds The Buffer`() async throws {
    let script = """
      awk 'BEGIN { printf "%*s", 500000, ""; printf "%*s", 500000, "" > "/dev/stderr" }'
      """

    let result = try await runner.run(executable: "/bin/sh", arguments: ["-c", script])

    #expect(result.standardOutput.count == 500_000)
    #expect(result.standardError.count == 500_000)
  }

  @Test
  func `Applies An Explicit Environment And Working Directory`() async throws {
    let result = try await runner.run(
      executable: "/bin/sh",
      arguments: ["-c", "printf '%s %s' \"$TAILREG_PROBE\" \"$(pwd)\""],
      environment: ["TAILREG_PROBE": "set"],
      workingDirectory: "/tmp"
    )

    #expect(result.standardOutputText.hasPrefix("set "))
    #expect(result.standardOutputText.hasSuffix("/tmp"))
  }
}
