import TailregCore
import Testing

@testable import TailregMultiplexer

@Suite
struct `Request classification tests` {
  @Test
  func `Next server actions accumulate generic and framework tags`() {
    let result = RequestClassifier.classify(
      RequestFacts(
        method: "POST",
        path: "/account",
        headers: [
          ("Next-Action", "abc123"),
          ("Content-Type", "application/json; charset=utf-8"),
          ("Content-Length", "18"),
          ("Sec-Fetch-Dest", "empty")
        ]
      )
    )

    #expect(
      result.tags.contains(
        all: [.nextJS, .frameworkAction, .fetchLike, .mutation, .structuredBody]
      )
    )
    #expect(result.ruleID == "nextjs.action")
    #expect(result.category == .frameworkData)
    #expect(result.requestBodyDisposition == .retain)
    #expect(result.responseBodyDisposition == .retain)
  }

  @Test
  func `Next prefetch wins over its framework data tag`() {
    let result = RequestClassifier.classify(
      RequestFacts(
        method: "GET",
        path: "/products",
        query: "_rsc=abc",
        headers: [
          ("RSC", "1"),
          ("Next-Router-Prefetch", "1")
        ]
      )
    )

    #expect(result.tags.contains(all: [.nextJS, .frameworkData, .prefetch]))
    #expect(result.ruleID == "nextjs.prefetch")
    #expect(result.requestBodyDisposition == .discard)
    #expect(result.responseBodyDisposition == .discard)
  }

  @Test
  func `Recognizes an enhanced SvelteKit form action`() {
    let result = RequestClassifier.classify(
      RequestFacts(
        method: "POST",
        path: "/account?/save",
        headers: [
          ("X-SvelteKit-Action", "true"),
          ("Content-Type", "multipart/form-data; boundary=tailreg")
        ]
      )
    )

    #expect(
      result.tags.contains(
        all: [.svelteKit, .frameworkAction, .fetchLike, .mutation, .formSubmission]
      )
    )
    #expect(result.ruleID == "sveltekit.action")
    #expect(result.requestBodyDisposition == .retain)
    #expect(result.responseBodyDisposition == .retain)
  }

  @Test(
    arguments: [
      ("/__data.json", "sveltekit.data", RequestTag.svelteKit),
      ("/products/_payload.json", "nuxt.data", RequestTag.nuxt),
      ("/products.data", "react-router.data", RequestTag.reactRouter),
      ("/_server-islands/card", "astro.data", RequestTag.astro)
    ]
  )
  func `Recognizes framework data transports`(
    path: String,
    ruleID: String,
    frameworkTag: RequestTag
  ) {
    let result = RequestClassifier.classify(RequestFacts(method: "GET", path: path))

    #expect(result.tags.contains(all: [frameworkTag, .frameworkData, .fetchLike]))
    #expect(result.ruleID == ruleID)
    #expect(result.responseBodyDisposition == .retain)
  }

  @Test(
    arguments: [
      ("POST", "/_app/remote/profile", "sveltekit.rpc", RequestTag.svelteKit),
      ("POST", "/_actions/save", "astro.action", RequestTag.astro),
      ("POST", "/_serverFn/getUser", "tanstack-start.rpc", RequestTag.tanStackStart)
    ]
  )
  func `Recognizes framework actions and RPCs`(
    method: String,
    path: String,
    ruleID: String,
    frameworkTag: RequestTag
  ) {
    let result = RequestClassifier.classify(RequestFacts(method: method, path: path))

    #expect(result.tags.contains(frameworkTag))
    #expect(result.tags.contains(.fetchLike))
    #expect(result.ruleID == ruleID)
    #expect(result.requestBodyDisposition == .retain)
    #expect(result.responseBodyDisposition == .retain)
  }

  @Test
  func `Classifies browser navigation and fetch independently`() {
    let navigation = RequestClassifier.classify(
      RequestFacts(
        method: "GET",
        path: "/dashboard",
        headers: [("Sec-Fetch-Mode", "navigate"), ("Sec-Fetch-Dest", "document")]
      )
    )
    let fetch = RequestClassifier.classify(
      RequestFacts(
        method: "GET",
        path: "/route/endpoint",
        headers: [("Sec-Fetch-Dest", "empty")]
      )
    )

    #expect(navigation.tags.contains(.document))
    #expect(navigation.ruleID == "browser.navigation")
    #expect(navigation.requestBodyDisposition == .discard)
    #expect(navigation.responseBodyDisposition == .provisional)
    #expect(fetch.tags.contains(.fetchLike))
    #expect(fetch.ruleID == "browser.fetch")
    #expect(fetch.responseBodyDisposition == .retain)
  }

  @Test
  func `Structured mutation retains both bodies`() {
    let result = RequestClassifier.classify(
      RequestFacts(
        method: "PATCH",
        path: "/api/profile",
        headers: [
          ("Content-Type", "application/vnd.example+json"),
          ("Content-Length", "12")
        ]
      )
    )

    #expect(result.tags.contains(all: [.fetchLike, .mutation, .structuredBody]))
    #expect(result.ruleID == "request.structured-or-mutation")
    #expect(result.requestBodyDisposition == .retain)
    #expect(result.responseBodyDisposition == .retain)
  }

  @Test
  func `Discards common assets probes telemetry and development traffic`() {
    let asset = RequestClassifier.classify(
      RequestFacts(
        method: "GET",
        path: "/logo.svg",
        headers: [("Sec-Fetch-Dest", "image")]
      )
    )
    let probe = RequestClassifier.classify(RequestFacts(method: "GET", path: "/favicon.ico"))
    let telemetry = RequestClassifier.classify(
      RequestFacts(method: "POST", path: "/_vercel/insights/event")
    )
    let vite = RequestClassifier.classify(RequestFacts(method: "GET", path: "/@vite/client"))

    #expect(asset.category == .asset)
    #expect(asset.responseBodyDisposition == .discard)
    #expect(probe.tags.contains(.backgroundProbe))
    #expect(probe.responseBodyDisposition == .discard)
    #expect(telemetry.category == .telemetry)
    #expect(telemetry.responseBodyDisposition == .discard)
    #expect(vite.tags.contains(all: [.vite, .devRuntime, .browserAsset]))
    #expect(vite.category == .devRuntime)
  }

  @Test
  func `Leaves unmatched traffic provisional for measurement`() {
    let result = RequestClassifier.classify(RequestFacts(method: "GET", path: "/opaque"))

    #expect(result.tags.isEmpty)
    #expect(result.category == .unknown)
    #expect(result.ruleID == "request.unclassified")
    #expect(result.requestBodyDisposition == .discard)
    #expect(result.responseBodyDisposition == .provisional)
  }

  @Test
  func `Discards generic WebSocket handshakes and HEAD response bodies`() {
    let webSocket = RequestClassifier.classify(
      RequestFacts(
        method: "GET",
        path: "/socket",
        headers: [("Upgrade", "websocket")]
      )
    )
    let head = RequestClassifier.classify(
      RequestFacts(
        method: "HEAD",
        path: "/api/profile",
        headers: [("Sec-Fetch-Dest", "empty")]
      )
    )

    #expect(webSocket.tags.contains(.webSocket))
    #expect(webSocket.category == .stream)
    #expect(webSocket.ruleID == "request.websocket")
    #expect(webSocket.responseBodyDisposition == .discard)
    #expect(head.tags.contains(all: [.headRequest, .fetchLike]))
    #expect(head.responseBodyDisposition == .discard)
  }
}
