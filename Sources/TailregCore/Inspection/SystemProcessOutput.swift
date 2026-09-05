import Dispatch

private let processOutputQueue = DispatchQueue(
  label: "com.tailreg.ports.processoutput",
  qos: .utility,
  attributes: .concurrent
)

extension ListeningProcess {
  /// Inspects this process's current standard output and standard error destinations.
  ///
  /// The result is a snapshot: a process may exit or replace either descriptor immediately after
  /// inspection. Unavailable output is represented in the returned value rather than thrown.
  public func output() async -> ProcessOutput {
    await withCheckedContinuation { continuation in
      processOutputQueue.async {
        continuation.resume(returning: platformProcessOutput(for: self.pid))
      }
    }
  }
}

private func platformProcessOutput(for pid: Int32) -> ProcessOutput {
  #if canImport(Glibc)
    return ProcFSProcessOutput.inspect(pid: pid)
  #elseif canImport(Darwin)
    return LibprocProcessOutput.inspect(pid: pid)
  #else
    return ProcessOutput(
      standardOutput: .unavailable(.unsupportedPlatform),
      standardError: .unavailable(.unsupportedPlatform)
    )
  #endif
}
