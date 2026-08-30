import Foundation
import HTTPTypes
import TailregCore
import UUIDV7

struct RequestFacts: Sendable {
  let method: String
  let path: String
  let queryNames: Set<String>
  let headers: [String: [String]]

  init(
    method: String,
    path: String,
    query: String? = nil,
    headers: [(String, String)] = []
  ) {
    self.method = method.uppercased()
    self.path = path.lowercased()
    self.queryNames = Set(
      (query ?? "")
        .split(separator: "&")
        .compactMap { pair in
          pair.split(separator: "=", maxSplits: 1).first
            .flatMap { String($0).removingPercentEncoding }?
            .lowercased()
        }
    )
    var normalizedHeaders: [String: [String]] = [:]
    for (name, value) in headers {
      normalizedHeaders[name.lowercased(), default: []].append(value)
    }
    self.headers = normalizedHeaders
  }

  init(method: String, path: String, query: String?, headers: HTTPFields) {
    self.init(
      method: method,
      path: path,
      query: query,
      headers: headers.map { ($0.name.canonicalName, $0.value) }
    )
  }

  func firstHeader(_ name: String) -> String? {
    headers[name.lowercased()]?.first
  }

  func header(_ name: String, contains token: String) -> Bool {
    headers[name.lowercased(), default: []]
      .contains { value in
        value.split(separator: ",")
          .contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == token }
      }
  }

  func hasHeader(_ name: String) -> Bool {
    headers[name.lowercased()] != nil
  }

  var contentType: String? {
    firstHeader("content-type")?
      .split(separator: ";", maxSplits: 1)
      .first
      .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
  }

  var accepts: [String] {
    headers["accept", default: []]
      .flatMap { value in
        value.split(separator: ",")
          .map { part in
            part.split(separator: ";", maxSplits: 1)[0]
              .trimmingCharacters(in: .whitespaces)
              .lowercased()
          }
      }
  }

  var hasPotentialBody: Bool {
    if let rawLength = firstHeader("content-length"), let length = Int(rawLength) {
      return length > 0
    }
    if hasHeader("transfer-encoding") { return true }
    return !["GET", "HEAD", "OPTIONS"].contains(method)
  }

  var isMutation: Bool {
    ["POST", "PUT", "PATCH", "DELETE"].contains(method)
  }
}

struct RequestClassification: Sendable {
  let policyVersion: Int
  let category: HTTPExchangeClassificationCategory
  let ruleID: String
  let tags: RequestTag
  let requestBodyDisposition: HTTPBodyCaptureDisposition
  let responseBodyDisposition: HTTPBodyCaptureDisposition

  func record(exchangeID: UUIDV7) -> HTTPExchangeClassificationRecord {
    HTTPExchangeClassificationRecord(
      exchangeID: exchangeID,
      policyVersion: policyVersion,
      category: category,
      ruleID: ruleID,
      tags: tags,
      requestBodyDisposition: requestBodyDisposition,
      responseBodyDisposition: responseBodyDisposition
    )
  }
}

enum RequestClassifier {
  static let currentPolicyVersion = 1

  static func classify(_ facts: RequestFacts) -> RequestClassification {
    let tags = recognize(facts)
    let requestBody: (HTTPBodyCaptureDisposition) -> HTTPBodyCaptureDisposition = { desired in
      facts.hasPotentialBody ? desired : .discard
    }

    let result:
      (
        category: HTTPExchangeClassificationCategory,
        ruleID: String,
        request: HTTPBodyCaptureDisposition,
        response: HTTPBodyCaptureDisposition
      )

    // The ordering here is the policy: the tags are additive, while the first
    // matching branch supplies the single, explainable decision.
    if tags.contains(.frameworkAction) {
      result = (.frameworkData, frameworkRule(tags, suffix: "action"), .retain, .retain)
    } else if tags.contains(.frameworkRPC) {
      result = (.frameworkData, frameworkRule(tags, suffix: "rpc"), .retain, .retain)
    } else if tags.contains(.telemetry) {
      result = (.telemetry, "request.telemetry", .discard, .discard)
    } else if tags.contains(.prefetch) {
      result = (.frameworkData, frameworkRule(tags, suffix: "prefetch"), .discard, .discard)
    } else if tags.contains(.frameworkData) {
      result = (.frameworkData, frameworkRule(tags, suffix: "data"), .retain, .retain)
    } else if tags.contains(.devRuntime) {
      result = (.devRuntime, frameworkRule(tags, suffix: "dev-runtime"), .discard, .discard)
    } else if tags.contains(any: [.browserAsset, .backgroundProbe]) {
      result = (.asset, "browser.asset-or-probe", .discard, .discard)
    } else if tags.contains(.corsPreflight) {
      result = (.unknown, "browser.cors-preflight", .discard, .discard)
    } else if tags.contains(.indefiniteStream) {
      result = (.stream, "request.indefinite-stream", .discard, .discard)
    } else if tags.contains(.rangeRequest) {
      result = (.stream, "request.range", .discard, .discard)
    } else if tags.contains(.webSocket) {
      result = (.stream, "request.websocket", .discard, .discard)
    } else if tags.contains(any: [.formSubmission, .structuredBody, .mutation]) {
      result = (.api, "request.structured-or-mutation", .retain, .retain)
    } else if tags.contains(.fetchLike) {
      result = (.api, "browser.fetch", .retain, .retain)
    } else if tags.contains(.document) {
      result = (.document, "browser.navigation", .retain, .provisional)
    } else {
      result = (.unknown, "request.unclassified", .provisional, .provisional)
    }

    return RequestClassification(
      policyVersion: Self.currentPolicyVersion,
      category: result.category,
      ruleID: result.ruleID,
      tags: tags,
      requestBodyDisposition: requestBody(result.request),
      responseBodyDisposition: facts.method == "HEAD" ? .discard : result.response
    )
  }

  private static func recognize(_ facts: RequestFacts) -> RequestTag {
    var tags: RequestTag = []
    let destination = facts.firstHeader("sec-fetch-dest")?.lowercased()
    let mode = facts.firstHeader("sec-fetch-mode")?.lowercased()

    if destination == "document" || destination == "iframe" || mode == "navigate" {
      tags.insert(.document)
    }
    if destination == "empty" || destination == "" || isLikelyAPIPath(facts.path)
      || facts.header("hx-request", contains: "true")
    {
      tags.insert(.fetchLike)
    }
    if Self.assetDestinations.contains(destination ?? "") { tags.insert(.browserAsset) }
    if facts.isMutation { tags.insert(.mutation) }
    if isStructured(facts.contentType) { tags.insert(.structuredBody) }
    if facts.isMutation && isForm(facts.contentType) { tags.insert(.formSubmission) }
    if facts.header("purpose", contains: "prefetch")
      || facts.header("sec-purpose", contains: "prefetch")
    {
      tags.insert(.prefetch)
    }
    if facts.method == "OPTIONS" && facts.hasHeader("access-control-request-method") {
      tags.insert(.corsPreflight)
    }
    if facts.hasHeader("range") { tags.insert(.rangeRequest) }
    if facts.accepts.contains("text/event-stream") { tags.insert(.indefiniteStream) }
    if facts.header("upgrade", contains: "websocket") { tags.insert(.webSocket) }
    if facts.method == "HEAD" { tags.insert(.headRequest) }
    if isBrowserProbe(facts.path) { tags.insert(.backgroundProbe) }
    if isTelemetry(facts.path, contentType: facts.contentType) { tags.insert(.telemetry) }

    recognizeNextJS(facts, into: &tags)
    recognizeSvelteKit(facts, into: &tags)
    recognizeNuxt(facts, into: &tags)
    recognizeReactRouter(facts, into: &tags)
    recognizeAstro(facts, into: &tags)
    recognizeTanStackStart(facts, into: &tags)
    recognizeVite(facts, into: &tags)
    return tags
  }

  private static func recognizeNextJS(_ facts: RequestFacts, into tags: inout RequestTag) {
    let isNextPath = facts.path.hasPrefix("/_next/")
    let isNextRequest =
      isNextPath
      || facts.path.hasPrefix("/__nextjs")
      || facts.hasHeader("rsc")
      || facts.hasHeader("next-action")
      || facts.hasHeader("next-router-prefetch")
      || facts.hasHeader("next-router-segment-prefetch")
      || facts.queryNames.contains("_rsc")
    guard isNextRequest else { return }
    tags.insert(.nextJS)

    if facts.hasHeader("next-action") {
      tags.formUnion([.frameworkAction, .fetchLike])
    }
    if facts.hasHeader("rsc") || facts.queryNames.contains("_rsc")
      || facts.path.hasPrefix("/_next/data/")
    {
      tags.formUnion([.frameworkData, .fetchLike])
    }
    if facts.hasHeader("next-router-prefetch")
      || facts.hasHeader("next-router-segment-prefetch")
    {
      tags.insert(.prefetch)
    }
    if facts.path.hasPrefix("/_next/static/") || facts.path.hasPrefix("/_next/image") {
      tags.insert(.browserAsset)
    }
    if facts.path.contains("webpack-hmr") || facts.path.contains("__nextjs") {
      tags.insert(.devRuntime)
    }
  }

  private static func recognizeSvelteKit(_ facts: RequestFacts, into tags: inout RequestTag) {
    if facts.header("x-sveltekit-action", contains: "true") {
      tags.formUnion([.svelteKit, .frameworkAction, .fetchLike])
    }
    if facts.path.hasSuffix("/__data.json") || facts.path.contains("/__data.json/") {
      tags.formUnion([.svelteKit, .frameworkData, .fetchLike])
    }
    if facts.path.hasPrefix("/_app/remote/") {
      tags.formUnion([.svelteKit, .frameworkRPC, .fetchLike])
    }
    if facts.path.hasPrefix("/_app/immutable/") {
      tags.formUnion([.svelteKit, .browserAsset])
    }
    if facts.path == "/_app/version.json" {
      tags.formUnion([.svelteKit, .backgroundProbe])
    }
  }

  private static func recognizeNuxt(_ facts: RequestFacts, into tags: inout RequestTag) {
    if facts.path.hasSuffix("/_payload.json") {
      tags.formUnion([.nuxt, .frameworkData, .fetchLike])
    }
    guard facts.path.hasPrefix("/_nuxt/") else { return }
    tags.insert(.nuxt)
    if facts.path.hasPrefix("/_nuxt/builds/") {
      tags.insert(.backgroundProbe)
    } else {
      tags.insert(.browserAsset)
    }
  }

  private static func recognizeReactRouter(_ facts: RequestFacts, into tags: inout RequestTag) {
    if facts.path.hasSuffix(".data") || facts.queryNames.contains("_data") {
      tags.formUnion([.reactRouter, .frameworkData, .fetchLike])
    }
  }

  private static func recognizeAstro(_ facts: RequestFacts, into tags: inout RequestTag) {
    if facts.path.hasPrefix("/_actions/") {
      tags.formUnion([.astro, .frameworkAction, .fetchLike])
    } else if facts.path.hasPrefix("/_server-islands/") {
      tags.formUnion([.astro, .frameworkData, .fetchLike])
    } else if facts.path.hasPrefix("/_astro/") {
      tags.formUnion([.astro, .browserAsset])
    }
  }

  private static func recognizeTanStackStart(_ facts: RequestFacts, into tags: inout RequestTag) {
    if facts.path.hasPrefix("/_serverfn/") || facts.path.hasPrefix("/_server-fn/") {
      tags.formUnion([.tanStackStart, .frameworkRPC, .fetchLike])
    }
  }

  private static func recognizeVite(_ facts: RequestFacts, into tags: inout RequestTag) {
    let isVitePath =
      facts.path.hasPrefix("/@vite/")
      || facts.path.hasPrefix("/@fs/")
      || facts.path.hasPrefix("/@id/")
      || facts.path == "/@react-refresh"
      || facts.path.contains("/node_modules/.vite/")
    let isViteWebSocket = facts.headers["sec-websocket-protocol", default: []]
      .contains { $0.lowercased().contains("vite-hmr") }
    if isVitePath || isViteWebSocket {
      tags.formUnion([.vite, .devRuntime])
      if isVitePath { tags.insert(.browserAsset) }
    }
  }

  private static func frameworkRule(_ tags: RequestTag, suffix: String) -> String {
    let prefix = frameworkNames.first { tags.contains($0.0) }?.1 ?? "framework"
    return "\(prefix).\(suffix)"
  }

  private static func isStructured(_ contentType: String?) -> Bool {
    guard let contentType else { return false }
    return contentType == "application/json"
      || contentType.hasSuffix("+json")
      || contentType == "application/xml"
      || contentType == "text/xml"
      || contentType.hasSuffix("+xml")
      || contentType == "application/graphql"
      || contentType == "application/x-www-form-urlencoded"
  }

  private static func isForm(_ contentType: String?) -> Bool {
    contentType == "application/x-www-form-urlencoded"
      || contentType == "multipart/form-data"
  }

  private static func isLikelyAPIPath(_ path: String) -> Bool {
    ["/api", "/graphql", "/rpc", "/trpc"]
      .contains { path == $0 || path.hasPrefix($0 + "/") }
  }

  private static func isBrowserProbe(_ path: String) -> Bool {
    path == "/favicon.ico"
      || path == "/robots.txt"
      || path == "/apple-touch-icon.png"
      || path.hasPrefix("/apple-touch-icon-")
      || path == "/.well-known/appspecific/com.chrome.devtools.json"
  }

  private static func isTelemetry(_ path: String, contentType: String?) -> Bool {
    let exactOrPrefix = [
      "/_vercel/insights/", "/_vercel/speed-insights/", "/cdn-cgi/rum", "/sentry/",
      "/telemetry/", "/analytics/", "/metrics/", "/vitals", "/track", "/collect"
    ]
    if exactOrPrefix.contains(where: { path == $0 || path.hasPrefix($0) }) { return true }
    return path.hasSuffix("/envelope/") && contentType == "application/x-sentry-envelope"
  }

  private static let assetDestinations: Set<String> = [
    "audio", "embed", "font", "image", "manifest", "object", "script", "serviceworker",
    "sharedworker", "style", "track", "video", "worker"
  ]

  private static let frameworkNames: [(RequestTag, String)] = [
    (.nextJS, "nextjs"), (.svelteKit, "sveltekit"), (.nuxt, "nuxt"),
    (.reactRouter, "react-router"), (.astro, "astro"),
    (.tanStackStart, "tanstack-start"), (.vite, "vite")
  ]
}
