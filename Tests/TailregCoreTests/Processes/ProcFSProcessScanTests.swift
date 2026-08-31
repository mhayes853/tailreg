#if canImport(Glibc)

  import Testing

  @testable import TailregCore

  @Suite
  struct `procfs table parsing tests` {
    private static let ipv4Table = """
        sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
         0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 29634949 1 0000000000000000 100 0 0 10 0
         1: 0100007F:8AE2 0100007F:1F90 01 00000000:00000000 00:00000000 00000000  1000        0 29634950 1 0000000000000000 20 4 30 10 -1
         2: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 29634951 1 0000000000000000 100 0 0 10 0
      """

    private static let ipv6Table = """
        sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
         0: 00000000000000000000000001000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 29635000 1 0000000000000000 100 0 0 10 0
         1: 00000000000000000000000000000000:0BB8 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 29635001 1 0000000000000000 100 0 0 10 0
      """

    @Test
    func `Reads An IPv4 Loopback Listener`() {
      let rows = ProcFSProcessScan.listeningRows(in: Self.ipv4Table)

      #expect(
        rows.contains(
          ProcFSProcessScan.Row(host: "127.0.0.1", port: PortNumber(8080)!, inode: 29_634_949)
        )
      )
    }

    @Test
    func `Reads An IPv4 Wildcard Listener`() {
      let rows = ProcFSProcessScan.listeningRows(in: Self.ipv4Table)

      #expect(
        rows.contains(
          ProcFSProcessScan.Row(host: "0.0.0.0", port: PortNumber(3000)!, inode: 29_634_951)
        )
      )
    }

    @Test
    func `Skips Rows That Are Not Listening`() {
      let rows = ProcFSProcessScan.listeningRows(in: Self.ipv4Table)

      #expect(rows.count == 2)
      #expect(!rows.contains { $0.inode == 29_634_950 })
    }

    @Test
    func `Reads An IPv6 Loopback Listener`() {
      let rows = ProcFSProcessScan.listeningRows(in: Self.ipv6Table)

      #expect(
        rows.contains(
          ProcFSProcessScan.Row(host: "::1", port: PortNumber(8080)!, inode: 29_635_000)
        )
      )
    }

    @Test
    func `Reads An IPv6 Wildcard Listener`() {
      let rows = ProcFSProcessScan.listeningRows(in: Self.ipv6Table)

      #expect(
        rows.contains(ProcFSProcessScan.Row(host: "::", port: PortNumber(3000)!, inode: 29_635_001))
      )
    }

    @Test
    func `Skips A Table That Is Only A Header`() {
      #expect(ProcFSProcessScan.listeningRows(in: "  sl  local_address rem_address   st\n").isEmpty)
    }

    @Test
    func `Rejects An Address That Is Not Four Or Sixteen Bytes`() {
      #expect(ProcFSProcessScan.host(fromHex: "0100") == nil)
      #expect(ProcFSProcessScan.host(fromHex: "") == nil)
    }

    @Test
    func `Reads The Parent From A Stat Line`() {
      let line = "1234 (sleep) S 999 1234 999 0 -1 4194560 0 0 0 0 0 0"

      #expect(ProcFSProcessScan.parentPID(inStatLine: line) == 999)
    }

    @Test
    func `Reads The Parent When The Name Holds Spaces And Parentheses`() {
      let line = "1234 (my (weird) name) S 999 1234 999 0 -1 4194560 0 0 0 0 0 0"

      #expect(ProcFSProcessScan.parentPID(inStatLine: line) == 999)
    }

    @Test
    func `Rejects A Stat Line With No Closing Parenthesis`() {
      #expect(ProcFSProcessScan.parentPID(inStatLine: "1234 sleep S 999") == nil)
    }
  }

#endif
