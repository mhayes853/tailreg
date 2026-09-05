import Foundation
import TailregCLI

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@main
enum TailregMain {
  static func main() async {
    if let status = SupervisedCommand.runIfRequested() {
      exit(status)
    }
    await TailregCommand.main()
  }
}
