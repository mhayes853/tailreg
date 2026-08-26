enum Fixtures {
  static let liveServeStatus = """
    {
      "TCP": { "443": { "HTTPS": true } },
      "Web": {
        "omarchy.tailc6bff1.ts.net:443": {
          "Handlers": { "/": { "Proxy": "http://127.0.0.1:3773" } }
        }
      }
    }
    """

  static let multiPathServeStatus = """
    {
      "TCP": { "8443": { "HTTPS": true } },
      "Web": {
        "node.example.ts.net:8443": {
          "Handlers": {
            "/": { "Proxy": "http://127.0.0.1:3000" },
            "/api": { "Proxy": "http://localhost:9000" },
            "/static": { "Path": "/var/www" }
          }
        }
      },
      "AllowFunnel": { "node.example.ts.net:8443": true }
    }
    """

  static let tcpForwardServeStatus = """
    {
      "TCP": {
        "2222": { "TCPForward": "127.0.0.1:22" },
        "10000": { "TCPForward": "127.0.0.1:5432", "TerminateTLS": "node.example.ts.net" }
      }
    }
    """

  static let nodeStatus = """
    {
      "Version": "1.102.3",
      "BackendState": "Running",
      "Self": { "DNSName": "omarchy.tailc6bff1.ts.net." }
    }
    """

  static let stoppedNodeStatus = """
    {
      "Version": "1.102.3",
      "BackendState": "Stopped",
      "Self": { "DNSName": "omarchy.tailc6bff1.ts.net." }
    }
    """
}
