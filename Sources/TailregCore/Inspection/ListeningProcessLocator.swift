/// Resolves a port to the local processes holding a listening socket on it.
///
/// Only processes the caller may inspect are visible, so an empty result does not mean the
/// port is free — it means nothing *of ours* is on it. Compose with ``PortProbe`` to tell
/// "nothing is listening" from "something is listening, but it is not yours".
public protocol ListeningProcessLocator: Sendable {
  func processes(listeningOn port: PortNumber) async throws -> [ListeningProcess]
}

/// Thrown when the scan itself could not run. Distinct from an empty result, which means the
/// scan ran and found nothing: the two need different messages downstream.
public enum ListeningProcessError: Error, Sendable, Equatable {
  case unsupportedPlatform
  case enumerationFailed(detail: String)
}
