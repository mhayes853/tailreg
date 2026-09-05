#if canImport(Glibc)

  import Foundation
  import Glibc

  /// Resolves listeners from `/proc`, in two passes: the port yields a socket inode from
  /// `/proc/net/tcp{,6}`, and the inode yields a pid by walking every readable `/proc/*/fd`.
  ///
  /// There is no reverse index from inode to pid, so the walk is the only route. It sees the
  /// caller's network namespace and readable processes only.
  enum ProcFSProcessScan {
    struct Row: Equatable {
      var host: String
      var port: PortNumber
      var inode: UInt64
    }

    static func processes(listeningOn port: PortNumber) throws -> [ListeningProcess] {
      var hostsByInode: [UInt64: Set<String>] = [:]
      for table in ["/proc/net/tcp", "/proc/net/tcp6"] {
        guard let contents = try? String(contentsOfFile: table, encoding: .utf8) else { continue }
        for row in listeningRows(in: contents) where row.port == port {
          hostsByInode[row.inode, default: []].insert(row.host)
        }
      }
      guard !hostsByInode.isEmpty else { return [] }
      return try attribute(hostsByInode)
    }

    // MARK: - Parsing

    static func listeningRows(in table: String) -> [Row] {
      var rows: [Row] = []
      for line in table.split(separator: "\n") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        // sl local_address rem_address st tx:rx tr:when retrnsmt uid timeout inode
        guard fields.count > 9, fields[3] == "0A" else { continue }
        let local = fields[1].split(separator: ":")
        guard local.count == 2,
          let port = PortNumber(hex: local[1]),
          let host = host(fromHex: local[0]),
          let inode = UInt64(fields[9])
        else { continue }
        rows.append(Row(host: host, port: port, inode: inode))
      }
      return rows
    }

    /// Each 8-character group is a `u32` the kernel printed with `%08X` straight from
    /// network-order storage, so the bytes of that integer *in host order* are the address
    /// bytes. Reading them back that way is correct on either endianness.
    static func host(fromHex hex: some StringProtocol) -> String? {
      guard hex.count == 8 || hex.count == 32 else { return nil }
      var bytes: [UInt8] = []
      var index = hex.startIndex
      while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 8)
        guard let word = UInt32(hex[index..<next], radix: 16) else { return nil }
        withUnsafeBytes(of: word) { bytes.append(contentsOf: $0) }
        index = next
      }

      var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      let family = bytes.count == 4 ? AF_INET : AF_INET6
      guard inet_ntop(family, bytes, &buffer, socklen_t(buffer.count)) != nil else { return nil }
      return String(cString: buffer)
    }

    /// The second field of `/proc/PID/stat` is the executable name in parentheses and may
    /// itself contain spaces and parentheses, so fields are read from the *last* `)`.
    static func parentPID(inStatLine line: some StringProtocol) -> Int32? {
      guard let close = line.lastIndex(of: ")") else { return nil }
      let fields = line[line.index(after: close)...]
        .split(separator: " ", omittingEmptySubsequences: true)
      guard fields.count >= 2 else { return nil }
      return Int32(fields[1])
    }

    // MARK: - Attribution

    private static func attribute(
      _ hostsByInode: [UInt64: Set<String>]
    ) throws -> [ListeningProcess] {
      var inodesByLink: [String: UInt64] = [:]
      for inode in hostsByInode.keys {
        inodesByLink["socket:[\(inode)]"] = inode
      }

      guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
        throw ListeningProcessError.enumerationFailed(detail: "/proc is not readable")
      }

      var found: [ListeningProcess] = []
      for entry in entries {
        guard let pid = Int32(entry) else { continue }
        // Other users' fd directories fail with EACCES, and a process can exit mid-scan.
        // Both are expected: skip rather than fail the whole scan.
        guard
          let descriptors = try? FileManager.default
            .contentsOfDirectory(atPath: "/proc/\(pid)/fd")
        else { continue }

        var hosts: Set<String> = []
        for descriptor in descriptors {
          guard let link = readLink("/proc/\(pid)/fd/\(descriptor)"),
            let inode = inodesByLink[link],
            let inodeHosts = hostsByInode[inode]
          else { continue }
          hosts.formUnion(inodeHosts)
        }
        guard !hosts.isEmpty else { continue }

        found.append(
          ListeningProcess(
            pid: pid,
            name: name(of: pid),
            parentPID: parentPID(of: pid),
            userID: userID(of: pid),
            hosts: hosts
          )
        )
      }
      return found.sorted { $0.pid < $1.pid }
    }

    /// Socket links are `socket:[N]`, so a buffer this size can only ever truncate paths that
    /// could not have matched anyway.
    private static func readLink(_ path: String) -> String? {
      var buffer = [CChar](repeating: 0, count: 128)
      let count = readlink(path, &buffer, buffer.count - 1)
      guard count > 0 else { return nil }
      buffer[count] = 0
      return String(cString: buffer)
    }

    private static func name(of pid: Int32) -> String? {
      guard let comm = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8) else {
        return nil
      }
      let trimmed = comm.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    private static func parentPID(of pid: Int32) -> Int32? {
      guard let line = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else {
        return nil
      }
      return parentPID(inStatLine: line)
    }

    private static func userID(of pid: Int32) -> UInt32? {
      var info = stat()
      // Unqualified: `Glibc.stat` names the struct, and only the free function takes arguments.
      guard stat("/proc/\(pid)", &info) == 0 else { return nil }
      return UInt32(info.st_uid)
    }
  }

#endif
