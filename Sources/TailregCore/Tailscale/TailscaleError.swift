public enum TailscaleError: Error, Sendable, Equatable {
  case notInstalled
  case daemonNotRunning(state: String)
  case operatorPermissionDenied
  case tailnetPortInUse(port: Int, existingTarget: String)
  case noLocalServerListening(port: Int)
  case noAvailableTailnetPort
  case bindingNotFound
  case malformedOutput(command: String, detail: String)
  case databaseUnavailable(path: String, detail: String)
  case lockUnavailable(path: String, detail: String)
  case commandFailed(argv: [String], exitCode: Int32, standardError: String)
}
