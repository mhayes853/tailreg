import Dispatch

private let locatorQueue = DispatchQueue(
  label: "com.tailreg.ports.listeningprocesslocator",
  attributes: .concurrent
)

public struct SystemListeningProcessLocator: ListeningProcessLocator {
  public init() {}

  public func processes(listeningOn port: PortNumber) async throws -> [ListeningProcess] {
    try await withCheckedThrowingContinuation { continuation in
      locatorQueue.async {
        continuation.resume(with: Result { try platformListeningProcesses(on: port) })
      }
    }
  }
}

func platformListeningProcesses(on port: PortNumber) throws -> [ListeningProcess] {
  #if canImport(Glibc)
    return try ProcFSProcessScan.processes(listeningOn: port)
  #elseif canImport(Darwin)
    return try LibprocProcessScan.processes(listeningOn: port)
  #else
    throw ListeningProcessError.unsupportedPlatform
  #endif
}
