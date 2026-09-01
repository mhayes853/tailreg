import ArgumentParser
import TailregCore
import Testing

@testable import TailregCLI

@Suite
struct `Up command tests` {
  @Test
  func `Parses CLI ports through PortNumber`() {
    #expect(PortNumber(argument: "443") == PortNumber(443))
    #expect(PortNumber(argument: "0") == nil)
    #expect(PortNumber(argument: "65536") == nil)
    #expect(PortNumber(argument: "not-a-port") == nil)
  }

  @Test
  func `Uses a configurable positive background startup timeout`() throws {
    #expect(try BackgroundStartupTimeout(environment: [:]) == .defaultValue)
    #expect(
      try BackgroundStartupTimeout(
        environment: [BackgroundStartupTimeout.environmentKey: "250"]
      ).duration == .milliseconds(250)
    )
    #expect(
      throws: BackgroundLaunchError.invalidTimeout("0")
    ) {
      try BackgroundStartupTimeout(
        environment: [BackgroundStartupTimeout.environmentKey: "0"]
      )
    }
  }
}
