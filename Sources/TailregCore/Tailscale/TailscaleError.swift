public enum TailscaleError: Error, Sendable, Equatable {
  case notInstalled
  case daemonNotRunning(state: String)
  case operatorPermissionDenied
  case tailnetPortInUse(port: PortNumber, existingTarget: String)
  case noLocalServerListening(port: PortNumber)
  case noAvailableTailnetPort
  case bindingNotFound
  case malformedOutput(command: String, detail: String)
  case databaseUnavailable(path: String, detail: String)
  case lockUnavailable(path: String, detail: String)
  case commandFailed(argv: [String], exitCode: Int32, standardError: String)
}

extension TailscaleError {
  /// Whether a bind lost the tailnet port it resolved to another writer of the serve
  /// configuration.
  ///
  /// Only a mount that is absent from the confirming read qualifies. `tailscale serve` reported
  /// success, so the request did reach the daemon; a configuration that no longer describes it is
  /// one that an overlapping write replaced, and resolving a port a second time reads that write
  /// as live and picks a different one.
  ///
  /// Nothing else is retried, because nothing else changes its answer. A daemon that is not
  /// installed, not running, or not willing to take orders from this user stays that way; an
  /// explicitly requested port that is already serving stays taken; an exhausted allocation pool
  /// stays exhausted; and output that would not decode came from a `tailscale` that disagrees
  /// with this one about its own format. A command that failed for a reason this code could not
  /// classify is left alone deliberately: it is as likely to be a misconfiguration as a
  /// collision, and retrying it only makes a clear error message arrive four times slower.
  static func isLostServeRace(_ error: any Error) -> Bool {
    (error as? TailscaleError) == .bindingNotFound
  }
}
