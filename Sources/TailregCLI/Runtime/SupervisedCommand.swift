import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Replaces the current Tailreg helper process with an application command in a new process group.
public enum SupervisedCommand {
  public static let marker = "_exec"

  /// Returns `nil` for normal Tailreg invocations and an exit status when setup or `execvp` fails.
  /// A successful `execvp` does not return.
  public static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
    guard arguments.dropFirst().first == marker else { return nil }
    let command = Array(arguments.dropFirst(2))
    guard !command.isEmpty else {
      writeError("tailreg: internal command supervisor received no command\n")
      return 64
    }
    if getpgrp() != getpid() {
      guard setpgid(0, 0) == 0 else {
        writeError("tailreg: could not create an application process group: \(posixMessage())\n")
        return 126
      }
    }
    signal(SIGINT, SIG_DFL)
    signal(SIGTERM, SIG_DFL)

    var pointers = command.map { strdup($0) }
    pointers.append(nil)
    defer {
      for pointer in pointers.dropLast() { free(pointer) }
    }
    let result = pointers.withUnsafeMutableBufferPointer { buffer in
      execvp(buffer[0]!, buffer.baseAddress!)
    }
    if result == -1 {
      writeError("tailreg: could not execute '\(command[0])': \(posixMessage())\n")
    }
    return 126
  }

  private static func posixMessage() -> String {
    String(cString: strerror(errno))
  }

  private static func writeError(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
  }
}
