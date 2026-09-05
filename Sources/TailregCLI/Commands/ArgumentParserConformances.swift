import ArgumentParser
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
