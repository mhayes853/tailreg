import Foundation
import TailregCore
import Testing

@Suite
struct `PortNumber tests` {
  @Test
  func `Rejects Zero Because It Is The Bind Any Sentinel`() {
    #expect(PortNumber(rawValue: 0) == nil)
    #expect(PortNumber(0) == nil)
  }

  @Test
  func `Rejects Values Above The Sixteen Bit Range`() {
    #expect(PortNumber(65536) == nil)
    #expect(PortNumber(70000) == nil)
  }

  @Test
  func `Rejects Negative Values`() {
    #expect(PortNumber(-1) == nil)
  }

  @Test
  func `Accepts The Range Boundaries`() {
    #expect(PortNumber(1)?.rawValue == 1)
    #expect(PortNumber(65535)?.rawValue == 65535)
  }

  @Test
  func `Reads A Network Byte Order PortNumber`() {
    #expect(PortNumber(bigEndian: UInt16(8080).bigEndian) == PortNumber(8080))
  }

  @Test
  func `Round Trips Through Network Byte Order`() throws {
    let port = try #require(PortNumber(3000))
    #expect(PortNumber(bigEndian: port.bigEndian) == port)
  }

  @Test
  func `Reads An Uppercase Hex PortNumber`() {
    #expect(PortNumber(hex: "1F90") == PortNumber(8080))
  }

  @Test
  func `Reads A Lowercase Hex PortNumber`() {
    #expect(PortNumber(hex: "1f90") == PortNumber(8080))
  }

  @Test
  func `Rejects Hex That Overflows`() {
    #expect(PortNumber(hex: "1FFFF") == nil)
  }

  @Test
  func `Rejects Hex Zero`() {
    #expect(PortNumber(hex: "0000") == nil)
  }

  @Test
  func `Rejects Hex That Is Not A Number`() {
    #expect(PortNumber(hex: "zzzz") == nil)
    #expect(PortNumber(hex: "") == nil)
  }

  @Test
  func `Bridges To A Plain Integer`() {
    #expect(PortNumber(8080)!.intValue == 8080)
  }

  @Test
  func `Describes Itself As A Bare Number`() {
    #expect(PortNumber(8080)!.description == "8080")
  }

  @Test
  func `Classifies The Privileged Range`() {
    #expect(PortNumber(80)!.isPrivileged)
    #expect(PortNumber(1023)!.isPrivileged)
    #expect(!PortNumber(1024)!.isPrivileged)
  }

  @Test
  func `Classifies The Ephemeral Range`() {
    #expect(!PortNumber(49151)!.isEphemeral)
    #expect(PortNumber(49152)!.isEphemeral)
    #expect(PortNumber(65535)!.isEphemeral)
  }

  @Test
  func `Orders By Number`() {
    let ports = [PortNumber(8080)!, PortNumber(443)!, PortNumber(3000)!]

    #expect(ports.sorted().map(\.rawValue) == [443, 3000, 8080])
  }

  @Test
  func `Encodes As A Bare Number`() throws {
    let encoded = try JSONEncoder().encode(PortNumber(8080)!)
    #expect(String(decoding: encoded, as: UTF8.self) == "8080")
  }

  @Test
  func `Round Trips Through Coding`() throws {
    let encoded = try JSONEncoder().encode(PortNumber(3000)!)
    #expect(try JSONDecoder().decode(PortNumber.self, from: encoded) == PortNumber(3000))
  }

  @Test
  func `Fails To Decode A Zero`() {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(PortNumber.self, from: Data("0".utf8))
    }
  }

  @Test
  func `Fails To Decode An Out Of Range Number`() {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(PortNumber.self, from: Data("70000".utf8))
    }
  }
}
