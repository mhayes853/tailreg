import SQLiteData

public struct RequestTag: OptionSet, Codable, Hashable, Sendable {
  public let rawValue: Int64

  public init(rawValue: Int64) {
    self.rawValue = rawValue
  }

  public init?(name: String) {
    guard let tag = Self.namedTags.first(where: { $0.1 == name.lowercased() })?.0 else {
      return nil
    }
    self = tag
  }

  // Browser and request shape. Persisted bit positions must never be reused.
  public static let document = Self(rawValue: Int64(1) << 0)
  public static let fetchLike = Self(rawValue: Int64(1) << 1)
  public static let formSubmission = Self(rawValue: Int64(1) << 2)
  public static let prefetch = Self(rawValue: Int64(1) << 3)
  public static let browserAsset = Self(rawValue: Int64(1) << 4)
  public static let corsPreflight = Self(rawValue: Int64(1) << 5)
  public static let rangeRequest = Self(rawValue: Int64(1) << 6)
  public static let indefiniteStream = Self(rawValue: Int64(1) << 7)

  // Semantic intent.
  public static let mutation = Self(rawValue: Int64(1) << 8)
  public static let structuredBody = Self(rawValue: Int64(1) << 9)
  public static let frameworkData = Self(rawValue: Int64(1) << 10)
  public static let frameworkAction = Self(rawValue: Int64(1) << 11)
  public static let frameworkRPC = Self(rawValue: Int64(1) << 12)
  public static let devRuntime = Self(rawValue: Int64(1) << 13)
  public static let backgroundProbe = Self(rawValue: Int64(1) << 14)
  public static let telemetry = Self(rawValue: Int64(1) << 15)

  // Framework and tool identity.
  public static let nextJS = Self(rawValue: Int64(1) << 16)
  public static let svelteKit = Self(rawValue: Int64(1) << 17)
  public static let nuxt = Self(rawValue: Int64(1) << 18)
  public static let reactRouter = Self(rawValue: Int64(1) << 19)
  public static let astro = Self(rawValue: Int64(1) << 20)
  public static let tanStackStart = Self(rawValue: Int64(1) << 21)
  public static let vite = Self(rawValue: Int64(1) << 22)

  // Additional transport shape.
  public static let webSocket = Self(rawValue: Int64(1) << 23)
  public static let headRequest = Self(rawValue: Int64(1) << 24)

  public func contains(all required: Self) -> Bool {
    intersection(required) == required
  }

  public func contains(any candidates: Self) -> Bool {
    !intersection(candidates).isEmpty
  }

  public var names: [String] {
    Self.namedTags.compactMap { tag, name in
      contains(tag) ? name : nil
    }
  }

  public static var allNames: [String] { namedTags.map(\.1) }

  private static let namedTags: [(Self, String)] = [
    (.document, "document"),
    (.fetchLike, "fetch-like"),
    (.formSubmission, "form-submission"),
    (.prefetch, "prefetch"),
    (.browserAsset, "browser-asset"),
    (.corsPreflight, "cors-preflight"),
    (.rangeRequest, "range-request"),
    (.indefiniteStream, "indefinite-stream"),
    (.mutation, "mutation"),
    (.structuredBody, "structured-body"),
    (.frameworkData, "framework-data"),
    (.frameworkAction, "framework-action"),
    (.frameworkRPC, "framework-rpc"),
    (.devRuntime, "dev-runtime"),
    (.backgroundProbe, "background-probe"),
    (.telemetry, "telemetry"),
    (.nextJS, "nextjs"),
    (.svelteKit, "sveltekit"),
    (.nuxt, "nuxt"),
    (.reactRouter, "react-router"),
    (.astro, "astro"),
    (.tanStackStart, "tanstack-start"),
    (.vite, "vite"),
    (.webSocket, "websocket"),
    (.headRequest, "head-request")
  ]
}

public enum HTTPExchangeClassificationCategory: String, Codable, Equatable, Sendable {
  case api
  case frameworkData = "framework-data"
  case document
  case asset
  case devRuntime = "dev-runtime"
  case telemetry
  case stream
  case unknown
}

public enum HTTPBodyCaptureDisposition: String, Codable, Equatable, Sendable {
  case retain
  case discard
  case provisional
}

extension HTTPExchangeClassificationCategory: QueryBindable, QueryDecodable {}
extension HTTPBodyCaptureDisposition: QueryBindable, QueryDecodable {}
