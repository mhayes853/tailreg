import ArgumentParser
import TailregCore

extension PortNumber: ExpressibleByArgument {
  public init?(argument: String) {
    self.init(rawValue: UInt16(argument) ?? 0)
  }
}
