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
    let setting = MillisecondsSetting.backgroundStartup
    #expect(try setting.resolve(from: [:]) == .seconds(60))
    #expect(try setting.resolve(from: [setting.environmentKey: "250"]) == .milliseconds(250))
    #expect(throws: MillisecondsSettingError.self) {
      try setting.resolve(from: [setting.environmentKey: "0"])
    }
  }

  @Test
  func `A tailnet port cannot be requested for a local-only project`() throws {
    #expect(throws: ValidationError.self) {
      try UpCommand.parse(["--local-only", "--tailnet-port", "8443"]).makeRequest()
    }
  }
}
