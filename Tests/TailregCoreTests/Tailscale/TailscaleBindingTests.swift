import Foundation
import TailregCore
import Testing

@Suite
struct `TailscaleBinding tests` {
  private func binding(
    tailnetPort: Int,
    proto: TailscaleServeProtocol = .https,
    mountPath: String = "/",
    target: TailscaleServeTarget = .localPort(3000)
  ) -> TailscaleBinding {
    TailscaleBinding(
      hostname: "node.example.ts.net",
      tailnetPort: tailnetPort,
      proto: proto,
      mountPath: mountPath,
      target: target,
      funnel: false
    )
  }

  @Test
  func `Elides The Default Port From The URL But Keeps Others`() {
    #expect(binding(tailnetPort: 443).url?.absoluteString == "https://node.example.ts.net/")
    #expect(binding(tailnetPort: 8443).url?.absoluteString == "https://node.example.ts.net:8443/")
    #expect(
      binding(tailnetPort: 80, proto: .http).url?.absoluteString == "http://node.example.ts.net/"
    )
  }

  @Test
  func `Preserves The Mount Path In The URL`() {
    #expect(
      binding(tailnetPort: 443, mountPath: "/api").url?.absoluteString
        == "https://node.example.ts.net/api"
    )
  }

  @Test
  func `Has No URL For A Non HTTP Protocol`() {
    #expect(binding(tailnetPort: 2222, proto: .tcp).url == nil)
  }

  @Test
  func `Exposes A Local Port Only For A Loopback Target`() {
    #expect(binding(tailnetPort: 443).localPort == 3000)
    #expect(binding(tailnetPort: 443, target: .path("/var/www")).localPort == nil)
  }

  @Test
  func `Matches A Claim On Serve Coordinates Rather Than Creation Time`() {
    let record = TailscaleBindingRecord(
      localPort: 3000,
      tailnetPort: 443,
      proto: .https,
      mountPath: "/",
      createdAt: Date(timeIntervalSince1970: 0)
    )

    #expect(record.claims(binding(tailnetPort: 443)))
    #expect(record.claims(binding(tailnetPort: 8443)) == false)
    #expect(record.claims(binding(tailnetPort: 443, mountPath: "/api")) == false)
    #expect(record.claims(binding(tailnetPort: 443, proto: .http)) == false)
  }
}
