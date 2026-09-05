import Foundation
import TailregCore

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// A real child process which owns a listening socket and emits only after the test asks it to.
/// It is deliberately implemented with `/bin/sh`, which is present in both CI environments.
public final class LogWritingSocketProcess {
  public let port: PortNumber
  public let pid: Int32
  public let standardOutputURL: URL
  public let standardErrorURL: URL

  private let gateURL: URL
  private let process: Process

  public init(in directory: URL, mergedOutput: Bool = false) throws {
    let listener = try LoopbackListener()
    port = listener.port
    standardOutputURL = directory.appending(path: "stdout.log")
    standardErrorURL = directory.appending(path: "stderr.log")
    gateURL = directory.appending(path: "emit")
    _ = FileManager.default.createFile(atPath: standardOutputURL.path, contents: Data())
    _ = FileManager.default.createFile(atPath: standardErrorURL.path, contents: Data())
    guard mkfifo(gateURL.path, 0o600) == 0 else { throw Failure.gate }

    let standardOutput = try FileHandle(forWritingTo: standardOutputURL)
    let standardError =
      mergedOutput ? standardOutput : try FileHandle(forWritingTo: standardErrorURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "IFS= read -r _ < \"$1\"; "
        + "printf 'fixture stdout\\n'; printf 'fixture stderr\\n' >&2; exec sleep 60",
      "tailreg-log-fixture",
      gateURL.path
    ]
    process.standardInput = FileHandle(fileDescriptor: listener.descriptor, closeOnDealloc: false)
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    listener.stop()

    self.process = process
    pid = process.processIdentifier
  }

  public func emit() throws {
    let gate = try FileHandle(forWritingTo: gateURL)
    defer { try? gate.close() }
    try gate.write(contentsOf: Data("\n".utf8))
  }

  public func stop() {
    guard process.isRunning else { return }
    kill(pid, SIGKILL)
    process.waitUntilExit()
  }

  public enum Failure: Error { case gate }
}
