#if canImport(Darwin)

  import Darwin
  import Foundation

  enum LibprocProcessOutput {
    static func inspect(pid: Int32) -> ProcessOutput {
      ProcessOutput(
        standardOutput: target(pid: pid_t(pid), descriptor: 1),
        standardError: target(pid: pid_t(pid), descriptor: 2)
      )
    }

    private static func target(pid: pid_t, descriptor: Int32) -> ProcessOutputTarget {
      guard let info = descriptorInfo(pid: pid, descriptor: descriptor) else {
        return processExists(pid) ? .unavailable(.inaccessible) : .unavailable(.processExited)
      }

      guard info.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else {
        switch info.proc_fdtype {
        case UInt32(PROX_FDTYPE_PIPE): return .unavailable(.pipe)
        case UInt32(PROX_FDTYPE_SOCKET): return .unavailable(.socket)
        default: return .unavailable(.nonRegularFile)
        }
      }

      var pathInfo = vnode_fdinfowithpath()
      let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
      guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDVNODEPATHINFO, &pathInfo, size) == size else {
        return .unavailable(.inaccessible)
      }
      var rawPath = pathInfo.pvip.vip_path
      let capacity = MemoryLayout.size(ofValue: rawPath)
      let path = withUnsafePointer(to: &rawPath) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
          String(cString: $0)
        }
      }
      guard !path.isEmpty else { return .unavailable(.inaccessible) }
      return ProcessOutputFile.openable(at: URL(fileURLWithPath: path))
    }

    private static func descriptorInfo(pid: pid_t, descriptor: Int32) -> proc_fdinfo? {
      let byteCount = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
      guard byteCount > 0 else { return nil }

      let count = Int(byteCount) / MemoryLayout<proc_fdinfo>.stride
      var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
      let written = descriptors.withUnsafeMutableBufferPointer {
        proc_pidinfo(
          pid,
          PROC_PIDLISTFDS,
          0,
          $0.baseAddress,
          Int32($0.count * MemoryLayout<proc_fdinfo>.stride)
        )
      }
      guard written > 0 else { return nil }
      return descriptors.prefix(Int(written) / MemoryLayout<proc_fdinfo>.stride)
        .first { $0.proc_fd == descriptor }
    }

    private static func processExists(_ pid: pid_t) -> Bool {
      kill(pid, 0) == 0 || errno == EPERM
    }
  }

#endif
