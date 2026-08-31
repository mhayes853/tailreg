#if canImport(Glibc)

  import Foundation

  enum ProcFSProcessOutput {
    static func inspect(pid: Int32) -> ProcessOutput {
      ProcessOutput(
        standardOutput: target(pid: pid, descriptor: 1),
        standardError: target(pid: pid, descriptor: 2)
      )
    }

    private static func target(pid: Int32, descriptor: Int32) -> ProcessOutputTarget {
      let descriptorPath = "/proc/\(pid)/fd/\(descriptor)"
      guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: descriptorPath)
      else {
        return processExists(pid) ? .unavailable(.inaccessible) : .unavailable(.processExited)
      }

      if destination.hasPrefix("pipe:[") { return .unavailable(.pipe) }
      if destination.hasPrefix("socket:[") { return .unavailable(.socket) }
      if destination == "/dev/null" { return .unavailable(.nullDevice) }
      if destination.hasPrefix("/dev/tty") || destination.hasPrefix("/dev/pts/") {
        return .unavailable(.terminal)
      }
      // A deleted file can still be held open by the process, but reopening its pathname would
      // either fail or attach to a different file.
      if destination.hasSuffix(" (deleted)") { return .unavailable(.inaccessible) }

      return ProcessOutputFile.openable(at: URL(fileURLWithPath: destination))
    }

    private static func processExists(_ pid: Int32) -> Bool {
      FileManager.default.fileExists(atPath: "/proc/\(pid)")
    }
  }

#endif
