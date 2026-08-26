import Foundation

public struct TailscaleLocator: Sendable {
  private let searchPaths: [String]

  public init(searchPaths: [String] = TailscaleLocator.defaultSearchPaths()) {
    self.searchPaths = searchPaths
  }

  public func locate() throws -> String {
    for candidate in searchPaths where FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    throw TailscaleError.notInstalled
  }

  public static func defaultSearchPaths(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String] {
    let fromPath = (environment["PATH"] ?? "")
      .split(separator: ":", omittingEmptySubsequences: true)
      .map { "\($0)/tailscale" }

    let wellKnown = [
      "/usr/bin/tailscale",
      "/usr/local/bin/tailscale",
      "/opt/homebrew/bin/tailscale",
      "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    ]

    var seen = Set<String>()
    return (fromPath + wellKnown).filter { seen.insert($0).inserted }
  }
}
