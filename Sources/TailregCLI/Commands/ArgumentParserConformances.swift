import ArgumentParser
import Foundation
import TailregCore

extension PortNumber: ExpressibleByArgument {
  public init?(argument: String) {
    self.init(text: argument)
  }
}

extension MuxRouteName: ExpressibleByArgument {
  public init?(argument: String) {
    self.init(rawValue: argument)
  }
}

/// Parsed at the boundary so that `--attach https://example.com` is refused by the parser, with
/// the usage message every other bad argument gets, rather than deep inside `up`.
extension LoopbackURL: ExpressibleByArgument {
  public init?(argument: String) {
    guard let url = URL(string: argument) else { return nil }
    self.init(url)
  }
}
