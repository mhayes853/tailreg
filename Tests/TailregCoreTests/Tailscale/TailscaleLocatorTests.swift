import TailregCore
import Testing

@Suite
struct `TailscaleLocator tests` {
  @Test
  func `Returns The First Executable Candidate`() throws {
    let temp = try TempDirectory()
    let expected = temp.makeExecutable("tailscale")

    let located = try TailscaleLocator(searchPaths: [temp.path("missing"), expected]).locate()

    #expect(located == expected)
  }

  @Test
  func `Honours Search Path Order`() throws {
    let temp = try TempDirectory()
    let first = temp.makeExecutable("first")
    let second = temp.makeExecutable("second")

    #expect(try TailscaleLocator(searchPaths: [first, second]).locate() == first)
    #expect(try TailscaleLocator(searchPaths: [second, first]).locate() == second)
  }

  @Test
  func `Skips Files That Exist But Are Not Executable`() throws {
    let temp = try TempDirectory()
    let notExecutable = try temp.makeFile("tailscale", contents: "text")
    let executable = temp.makeExecutable("real")

    #expect(try TailscaleLocator(searchPaths: [notExecutable, executable]).locate() == executable)
  }

  @Test
  func `Throws Not Installed When Nothing Matches`() throws {
    let temp = try TempDirectory()

    #expect(throws: TailscaleError.notInstalled) {
      try TailscaleLocator(searchPaths: [temp.path("absent")]).locate()
    }
  }

  @Test
  func `Does Not Repeat A Location Present In Both Path And The Well Known List`() {
    let paths = TailscaleLocator.defaultSearchPaths(environment: ["PATH": "/usr/bin"])

    #expect(paths.filter { $0 == "/usr/bin/tailscale" }.count == 1)
  }
}
