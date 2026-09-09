import ArgumentParser
import TailregCore
import Testing

@testable import TailregCLI

/// What the flags mean, and which combinations of them mean nothing. Every rejection here is a
/// combination that would otherwise be obeyed in part.
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
  func `Waits a minute for background startup by default`() throws {
    #expect(try MillisecondsSetting.backgroundStartup.resolve(from: [:]) == .seconds(60))
  }

  @Test
  func `A tailnet port cannot be requested for a local-only project`() throws {
    #expect(throws: ValidationError.self) {
      try UpCommand.parse(["--local-only", "--tailnet-port", "8443"]).makeRequest()
    }
  }

  /// The port would win over the attach URL's, so `up` would wait for readiness on a port that
  /// has nothing to do with the route it is about to publish.
  @Test
  func `A port cannot be given for an attached application`() throws {
    #expect(throws: ValidationError.self) {
      try UpCommand
        .parse(["--app", "docs", "--attach", "http://127.0.0.1:4321", "--port", "4321"])
        .makeRequest()
    }
  }

  /// Refused by the parser rather than by `up`: an upstream Tailreg cannot reach on loopback is
  /// somebody else's server, and publishing it on a tailnet is not a thing to do halfway.
  @Test
  func `A non-loopback attach URL is not an argument`() {
    #expect(throws: (any Error).self) {
      try UpCommand.parse(["--app", "docs", "--attach", "http://example.com:80"])
    }
  }

  @Test
  func `An ad hoc command after -- becomes the application's source`() throws {
    let request =
      try UpCommand
      .parse(["--app", "docs", "--route", "docs", "--port", "4321", "--", "npm", "run", "dev"])
      .makeRequest()

    guard case .adHoc(let name, let route, let source) = request.selection else {
      Issue.record("expected an ad hoc selection, got \(request.selection)")
      return
    }
    #expect(name == "docs")
    #expect(route == MuxRouteName(rawValue: "docs"))
    guard case .command(let arguments, let port) = source else {
      Issue.record("expected a command source, got \(source)")
      return
    }
    #expect(arguments == ["npm", "run", "dev"])
    #expect(port == PortNumber(4321))
  }

  @Test
  func `Application names without --app select the configuration`() throws {
    let request = try UpCommand.parse(["web", "api"]).makeRequest()

    guard case .configured(let names) = request.selection else {
      Issue.record("expected a configured selection, got \(request.selection)")
      return
    }
    #expect(names == ["web", "api"])
  }
}
