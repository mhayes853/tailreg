import Foundation
import Testing

@testable import TailregCore

@Suite(.timeLimit(.minutes(1)))
struct `Process launcher tests` {
  private let launcher = SystemProcessLauncher()

  @Test
  func `Launches A Command And Streams Both Output Descriptors`() async throws {
    let process = try launcher.launch(
      ProcessCommand(
        executable: "/bin/sh",
        arguments: ["-c", "printf 'from stdout\\n'; printf 'from stderr\\n' >&2"]
      )
    )

    async let standardOutput = collect(process.standardOutput)
    async let standardError = collect(process.standardError)
    let exit = await process.waitForExit()
    let output = await standardOutput
    let error = await standardError

    #expect(exit == ProcessExit(code: 0, wasTerminatedBySignal: false))
    #expect(output.map(\.message) == ["from stdout"])
    #expect(output.allSatisfy { $0.stream == .standardOutput })
    #expect(error.map(\.message) == ["from stderr"])
    #expect(error.allSatisfy { $0.stream == .standardError })
  }

  @Test
  func `Passes Parsed Arguments Literally Without A Shell`() async throws {
    let process = try launcher.launch(
      ProcessCommand(
        executable: printfPath(),
        arguments: ["%s\\n", "space value", "$(not expanded)", "; not executed", "*.swift"]
      )
    )

    async let output = collect(process.standardOutput)
    let exit = await process.waitForExit()

    #expect(exit == ProcessExit(code: 0, wasTerminatedBySignal: false))
    #expect(
      await output.map(\.message)
        == ["space value", "$(not expanded)", "; not executed", "*.swift"]
    )
  }

  @Test
  func `Resolves An Executable From Path`() async throws {
    let process = try launcher.launch(
      ProcessCommand(executable: "printf", arguments: ["resolved\\n"])
    )
    async let output = collect(process.standardOutput)

    #expect(await process.waitForExit() == ProcessExit(code: 0, wasTerminatedBySignal: false))
    #expect(await output.map(\.message) == ["resolved"])
  }

  @Test
  func `Reports AMissingExecutable`() {
    #expect(throws: ProcessLaunchError.executableNotFound("tailreg-no-such-command")) {
      _ = try launcher.launch(ProcessCommand(executable: "tailreg-no-such-command"))
    }
  }

  @Test
  func `Rejects AnEmptyExecutable And NulArguments`() {
    #expect(throws: ProcessLaunchError.emptyExecutable) {
      _ = try launcher.launch(ProcessCommand(executable: ""))
    }
    #expect(throws: ProcessLaunchError.nulByte) {
      _ = try launcher.launch(
        ProcessCommand(executable: printfPath(), arguments: ["bad\0argument"])
      )
    }
  }

  @Test
  func `Drains ANoisyChild Before Any Consumer Subscribes`() async throws {
    let process = try launcher.launch(
      ProcessCommand(
        executable: "/bin/sh",
        arguments: ["-c", "dd if=/dev/zero bs=65536 count=16 2>/dev/null"]
      )
    )

    #expect(await process.waitForExit() == ProcessExit(code: 0, wasTerminatedBySignal: false))
  }

  @Test
  func `Terminates ALaunchedChild`() async throws {
    let process = try launcher.launch(ProcessCommand(executable: sleepPath(), arguments: ["30"]))
    try await Task.sleep(for: .milliseconds(100))
    process.terminate()

    let exit = await process.waitForExit()
    #expect(exit.wasTerminatedBySignal)
  }

  private func collect(_ output: AsyncStream<LogLine>) async -> [LogLine] {
    var collected: [LogLine] = []
    for await line in output {
      collected.append(line)
    }
    return collected
  }

  private func printfPath() -> String {
    ["/usr/bin/printf", "/bin/printf"].first { FileManager.default.isExecutableFile(atPath: $0) }
      ?? "/usr/bin/printf"
  }

  private func sleepPath() -> String {
    ["/usr/bin/sleep", "/bin/sleep"].first { FileManager.default.isExecutableFile(atPath: $0) }
      ?? "/usr/bin/sleep"
  }
}
