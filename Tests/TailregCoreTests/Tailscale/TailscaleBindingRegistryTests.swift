import Foundation
import TailregCore
import Testing

@Suite
struct `TailscaleBindingRegistry tests` {
  private func record(
    localPort: Int = 3000,
    tailnetPort: Int = 443,
    proto: TailscaleServeProtocol = .https,
    mountPath: String = "/"
  ) -> TailscaleBindingRecord {
    TailscaleBindingRecord(
      localPort: localPort,
      tailnetPort: tailnetPort,
      proto: proto,
      mountPath: mountPath,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  @Test
  func `Reads An Absent File As No Claims`() async throws {
    let temp = try TempDirectory()
    let registry = TailscaleBindingRegistry(path: temp.path("bindings.json"))

    #expect(try await registry.records().isEmpty)
  }

  @Test
  func `Round Trips A Claim Through Disk`() async throws {
    let temp = try TempDirectory()
    let path = temp.path("bindings.json")
    let written = record()

    try await TailscaleBindingRegistry(path: path).add(written)

    #expect(try await TailscaleBindingRegistry(path: path).records() == [written])
  }

  @Test
  func `Creates The Containing Directory On First Write`() async throws {
    let temp = try TempDirectory()
    let path = temp.path("nested/deeper/bindings.json")

    try await TailscaleBindingRegistry(path: path).add(record())

    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test
  func `Replaces Rather Than Duplicates A Claim On The Same Coordinates`() async throws {
    let temp = try TempDirectory()
    let registry = TailscaleBindingRegistry(path: temp.path("bindings.json"))

    try await registry.add(record(localPort: 3000))
    try await registry.add(record(localPort: 4000))

    let records = try await registry.records()
    #expect(records.count == 1)
    #expect(records[0].localPort == 4000)
  }

  @Test
  func `Removing A Claim Leaves The Others Intact`() async throws {
    let temp = try TempDirectory()
    let registry = TailscaleBindingRegistry(path: temp.path("bindings.json"))
    try await registry.add(record(tailnetPort: 443))
    try await registry.add(record(localPort: 4000, tailnetPort: 8443))

    try await registry.removeClaim(tailnetPort: 443, proto: .https, mountPath: "/")

    #expect(try await registry.records().map(\.tailnetPort) == [8443])
  }

  @Test
  func `Removing A Claim That Is Not Held Is A No Op`() async throws {
    let temp = try TempDirectory()
    let registry = TailscaleBindingRegistry(path: temp.path("bindings.json"))
    try await registry.add(record())

    try await registry.removeClaim(tailnetPort: 9999, proto: .https, mountPath: "/")

    #expect(try await registry.records().count == 1)
  }

  @Test
  func `Fails Loudly On A Corrupt File Rather Than Discarding Ownership`() async throws {
    let temp = try TempDirectory()
    let path = try temp.makeFile("bindings.json", contents: "{ truncated")

    await #expect(throws: TailscaleError.self) {
      try await TailscaleBindingRegistry(path: path).records()
    }
  }

  @Test
  func `Keeps Every Claim When Writers Run Concurrently`() async throws {
    let temp = try TempDirectory()
    let registry = TailscaleBindingRegistry(path: temp.path("bindings.json"))

    await withTaskGroup(of: Void.self) { group in
      for port in 3000..<3020 {
        group.addTask {
          try? await registry.add(self.record(localPort: port, tailnetPort: port))
        }
      }
    }

    #expect(try await registry.records().count == 20)
  }
}
