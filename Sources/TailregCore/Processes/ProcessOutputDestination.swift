import Foundation

/// A best-effort snapshot of the destinations currently connected to a local process's output
/// descriptors.
///
/// A process's output cannot usually be recovered after launch: terminals and pipes have no
/// passive second-reader interface. Regular files are the supported attachable case.
public struct ProcessOutput: Sendable, Hashable {
  public let standardOutput: ProcessOutputTarget
  public let standardError: ProcessOutputTarget

  public init(standardOutput: ProcessOutputTarget, standardError: ProcessOutputTarget) {
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

public enum ProcessOutputTarget: Sendable, Hashable {
  case regularFile(ProcessOutputFile)
  case unavailable(ProcessOutputUnavailableReason)
}

/// A regular file opened by a process as an output destination.
public struct ProcessOutputFile: Sendable, Hashable {
  public let url: URL
  public let identity: ProcessOutputFileIdentity

  public init(url: URL, identity: ProcessOutputFileIdentity) {
    self.url = url
    self.identity = identity
  }
}

/// An on-disk identity used to recognize `stdout` and `stderr` redirected to the same file.
public struct ProcessOutputFileIdentity: Sendable, Hashable {
  public let device: UInt64
  public let inode: UInt64

  public init(device: UInt64, inode: UInt64) {
    self.device = device
    self.inode = inode
  }
}

public enum ProcessOutputUnavailableReason: Sendable, Hashable {
  case terminal
  case pipe
  case socket
  case nullDevice
  case nonRegularFile
  case inaccessible
  case processExited
  case unsupportedPlatform
}
