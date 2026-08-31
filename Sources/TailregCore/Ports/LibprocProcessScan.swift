#if canImport(Darwin)

  import Darwin

  /// Resolves listeners through `libproc`: every pid, every socket descriptor, matched on the
  /// local port of listening TCP sockets.
  ///
  /// Descriptor inspection returns `EPERM` for other users' processes, so the scan sees the
  /// caller's own processes only.
  enum LibprocProcessScan {
    static func processes(listeningOn port: PortNumber) throws -> [ListeningProcess] {
      var found: [ListeningProcess] = []
      for pid in try allPIDs() {
        let hosts = listeningHosts(pid: pid, port: port)
        guard !hosts.isEmpty else { continue }
        let info = bsdInfo(of: pid)
        found.append(
          ListeningProcess(
            pid: pid,
            name: name(of: pid),
            parentPID: info.map { Int32(bitPattern: $0.pbi_ppid) },
            userID: info?.pbi_uid,
            hosts: hosts
          )
        )
      }
      return found.sorted { $0.pid < $1.pid }
    }

    // MARK: - Enumeration

    private static func allPIDs() throws -> [pid_t] {
      let sized = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
      guard sized > 0 else {
        throw ListeningProcessError.enumerationFailed(detail: "proc_listpids returned \(sized)")
      }

      // Processes can appear between sizing and reading, so ask for slack.
      let capacity = Int(sized) / MemoryLayout<pid_t>.size + 64
      var pids = [pid_t](repeating: 0, count: capacity)
      let written = pids.withUnsafeMutableBufferPointer {
        proc_listpids(
          UInt32(PROC_ALL_PIDS),
          0,
          $0.baseAddress,
          Int32($0.count * MemoryLayout<pid_t>.size)
        )
      }
      guard written > 0 else {
        throw ListeningProcessError.enumerationFailed(detail: "proc_listpids returned \(written)")
      }
      return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    private static func listeningHosts(pid: pid_t, port: PortNumber) -> Set<String> {
      let sized = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
      // Not an error: other users' processes are denied, and a process can exit mid-scan.
      guard sized > 0 else { return [] }

      let capacity = Int(sized) / MemoryLayout<proc_fdinfo>.stride + 32
      var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
      let written = descriptors.withUnsafeMutableBufferPointer {
        proc_pidinfo(
          pid,
          PROC_PIDLISTFDS,
          0,
          $0.baseAddress,
          Int32($0.count * MemoryLayout<proc_fdinfo>.stride)
        )
      }
      guard written > 0 else { return [] }

      var hosts: Set<String> = []
      let count = Int(written) / MemoryLayout<proc_fdinfo>.stride
      for descriptor in descriptors.prefix(count)
      where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
        if let host = listeningHost(pid: pid, fd: descriptor.proc_fd, port: port) {
          hosts.insert(host)
        }
      }
      return hosts
    }

    private static func listeningHost(pid: pid_t, fd: Int32, port: PortNumber) -> String? {
      var info = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
      guard info.psi.soi_kind == Int32(SOCKINFO_TCP) else { return nil }

      let tcp = info.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { return nil }
      // `insi_lport` is network byte order in the low half of an `int`.
      guard PortNumber(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) == port
      else {
        return nil
      }
      return host(from: tcp.tcpsi_ini)
    }

    /// IPv6 is checked first: a dual-stack socket sets both flags, and reporting `::` for it
    /// matches what Linux shows in `/proc/net/tcp6`.
    private static func host(from info: in_sockinfo) -> String? {
      var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      var info = info
      if info.insi_vflag & UInt8(INI_IPV6) != 0 {
        guard inet_ntop(AF_INET6, &info.insi_laddr.ina_6, &buffer, socklen_t(buffer.count)) != nil
        else { return nil }
      } else if info.insi_vflag & UInt8(INI_IPV4) != 0 {
        guard
          inet_ntop(
            AF_INET,
            &info.insi_laddr.ina_46.i46a_addr4,
            &buffer,
            socklen_t(buffer.count)
          ) != nil
        else { return nil }
      } else {
        return nil
      }
      return String(cString: buffer)
    }

    // MARK: - Metadata

    private static func name(of pid: pid_t) -> String? {
      var path = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
      if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
        let resolved = String(cString: path)
        if let component = resolved.split(separator: "/").last {
          return String(component)
        }
      }

      var name = [CChar](repeating: 0, count: 256)
      guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
      let resolved = String(cString: name)
      return resolved.isEmpty ? nil : resolved
    }

    private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
      return info
    }
  }

#endif
