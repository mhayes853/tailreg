import Foundation
import TailregCore
import TailregTestSupport
import Testing

@Suite
struct `TailscaleBinding tests` {
  private func binding(
    tailnetPort: PortNumber,
    proto: TailscaleServeProtocol = .https,
    mountPath: String = "/",
    target: TailscaleServeTarget = .localPort(.fixed(3000))
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
    #expect(binding(tailnetPort: .fixed(443)).url?.absoluteString == "https://node.example.ts.net/")
    #expect(
      binding(tailnetPort: .fixed(8443)).url?.absoluteString == "https://node.example.ts.net:8443/"
    )
    #expect(
      binding(tailnetPort: .fixed(80), proto: .http).url?.absoluteString
        == "http://node.example.ts.net/"
    )
  }

  @Test
  func `Preserves The Mount Path In The URL`() {
    #expect(
      binding(tailnetPort: .fixed(443), mountPath: "/api").url?.absoluteString
        == "https://node.example.ts.net/api"
    )
  }

  @Test
  func `Has No URL For A Non HTTP Protocol`() {
    #expect(binding(tailnetPort: .fixed(2222), proto: .tcp).url == nil)
  }

  @Test
  func `Exposes A Local Port Only For A Loopback Target`() {
    #expect(binding(tailnetPort: .fixed(443)).localPort == .fixed(3000))
    #expect(binding(tailnetPort: .fixed(443), target: .path("/var/www")).localPort == nil)
  }
}
