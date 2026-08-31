import Foundation
import TailregCore

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// A child process that holds a listening socket as its standard input and does nothing else.
///
/// The parent binds and listens, hands the descriptor to the child, then closes its own copy,
/// so the port is attributable to the child alone. That is what separates a locator that walks
/// other processes from one that only ever inspects itself.
final class SocketHoldingProcess {
  enum Output {
    case nullDevice
    case pipe
  }

  let port: PortNumber
  let pid: Int32
  private let process: Process
  private let pipes: (standardOutput: Pipe, standardError: Pipe)?

  init(output: Output = .nullDevice) throws {
    let listener = try LoopbackListener()
    port = listener.port

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["60"]
    process.standardInput = FileHandle(
      fileDescriptor: listener.descriptor,
      closeOnDealloc: false
    )
    switch output {
    case .nullDevice:
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      pipes = nil
    case .pipe:
      let standardOutput = Pipe()
      let standardError = Pipe()
      process.standardOutput = standardOutput
      process.standardError = standardError
      pipes = (standardOutput, standardError)
    }
    try process.run()

    // The child's descriptor table was copied at spawn, so the parent's copy is now redundant.
    listener.stop()

    self.process = process
    pid = process.processIdentifier
  }

  func stop() {
    // SIGKILL rather than `terminate()`: a leaked child would otherwise hold the test process
    // open for the whole of its sleep.
    kill(pid, SIGKILL)
    process.waitUntilExit()
  }
}
