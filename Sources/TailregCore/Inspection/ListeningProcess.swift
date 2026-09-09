/// A local process holding a listening socket on a port.
public struct ListeningProcess: Sendable, Hashable {
  public let pid: Int32

  /// Best effort: the executable's basename. Nil when the process exited mid-scan.
  public let name: String?

  /// Carried because the socket and the output streams often sit on different processes: a
  /// `npm run dev` tree binds the port in the leaf while `stdout` is inherited from the root.
  public let parentPID: Int32?

  public let userID: UInt32?

  /// The addresses bound on the queried port. A dual-stack listener yields two.
  public let hosts: Set<String>

  public init(
    pid: Int32,
    name: String?,
    parentPID: Int32?,
    userID: UInt32?,
    hosts: Set<String>
  ) {
    self.pid = pid
    self.name = name
    self.parentPID = parentPID
    self.userID = userID
    self.hosts = hosts
  }
}
