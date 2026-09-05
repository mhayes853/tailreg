import Foundation
import SQLiteData
import UUIDV7

public enum HTTPExchangeOutcome: String, Codable, Equatable, Sendable {
  case inProgress = "in-progress"
  case complete
  case failed
  case cancelled
  case abandoned
}

extension HTTPExchangeOutcome: QueryBindable, QueryDecodable {}

public enum HTTPExchangeBodyDirection: String, Codable, Equatable, Sendable {
  case request
  case response
}

extension HTTPExchangeBodyDirection: QueryBindable, QueryDecodable {}

@Selection
public struct CapturedHTTPHeader: Codable, Equatable, Hashable, Sendable {
  public var name: String
  public var value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

@Table("httpExchanges")
public struct HTTPExchangeRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var routeID: UUIDV7
  public var method: String
  public var host: String?
  public var path: String
  public var query: String?
  @Column(as: [CapturedHTTPHeader].JSONRepresentation.self)
  public var requestHeaders: [CapturedHTTPHeader]
  public var requestBodyBytes: Int
  public var startedAt: Date
  public var responseStartedAt: Date?
  public var statusCode: Int?
  @Column(as: [CapturedHTTPHeader].JSONRepresentation?.self)
  public var responseHeaders: [CapturedHTTPHeader]?
  public var responseBodyBytes: Int
  public var completedAt: Date?
  public var outcome: HTTPExchangeOutcome
  public var failure: String?
  public var tailscaleUserLogin: String?
  public var tailscaleUserName: String?

  public init(
    id: UUIDV7 = UUIDV7(),
    routeID: UUIDV7,
    method: String,
    host: String? = nil,
    path: String,
    query: String? = nil,
    requestHeaders: [CapturedHTTPHeader],
    requestBodyBytes: Int = 0,
    startedAt: Date,
    responseStartedAt: Date? = nil,
    statusCode: Int? = nil,
    responseHeaders: [CapturedHTTPHeader]? = nil,
    responseBodyBytes: Int = 0,
    completedAt: Date? = nil,
    outcome: HTTPExchangeOutcome = .inProgress,
    failure: String? = nil,
    tailscaleUserLogin: String? = nil,
    tailscaleUserName: String? = nil
  ) {
    self.id = id
    self.routeID = routeID
    self.method = method
    self.host = host
    self.path = path
    self.query = query
    self.requestHeaders = requestHeaders
    self.requestBodyBytes = requestBodyBytes
    self.startedAt = startedAt
    self.responseStartedAt = responseStartedAt
    self.statusCode = statusCode
    self.responseHeaders = responseHeaders
    self.responseBodyBytes = responseBodyBytes
    self.completedAt = completedAt
    self.outcome = outcome
    self.failure = failure
    self.tailscaleUserLogin = tailscaleUserLogin
    self.tailscaleUserName = tailscaleUserName
  }
}

@Table("httpExchangeBodies")
public struct HTTPExchangeBodyRecord: Hashable, Sendable {
  public var exchangeID: UUIDV7
  public var direction: HTTPExchangeBodyDirection
  public var contentType: String?
  public var content: Data?
  public var observedByteCount: Int
  public var omitted: Bool

  public init(
    exchangeID: UUIDV7,
    direction: HTTPExchangeBodyDirection,
    contentType: String? = nil,
    content: Data?,
    observedByteCount: Int,
    omitted: Bool
  ) {
    self.exchangeID = exchangeID
    self.direction = direction
    self.contentType = contentType
    self.content = content
    self.observedByteCount = observedByteCount
    self.omitted = omitted
  }
}

@Table("httpExchangeClassifications")
public struct HTTPExchangeClassificationRecord: Hashable, Sendable {
  public var exchangeID: UUIDV7
  public var policyVersion: Int
  public var category: HTTPExchangeClassificationCategory
  public var ruleID: String
  @Column(as: RequestTag.RawRepresentation.self)
  public var tags: RequestTag
  public var requestBodyDisposition: HTTPBodyCaptureDisposition
  public var responseBodyDisposition: HTTPBodyCaptureDisposition

  public init(
    exchangeID: UUIDV7,
    policyVersion: Int,
    category: HTTPExchangeClassificationCategory,
    ruleID: String,
    tags: RequestTag,
    requestBodyDisposition: HTTPBodyCaptureDisposition,
    responseBodyDisposition: HTTPBodyCaptureDisposition
  ) {
    self.exchangeID = exchangeID
    self.policyVersion = policyVersion
    self.category = category
    self.ruleID = ruleID
    self.tags = tags
    self.requestBodyDisposition = requestBodyDisposition
    self.responseBodyDisposition = responseBodyDisposition
  }
}

@Table("httpExchangeClassificationRefinements")
public struct HTTPExchangeClassificationRefinementRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var exchangeID: UUIDV7
  public var classifierID: String
  public var classifierVersion: String
  public var usefulness: RequestUsefulness?
  public var category: HTTPExchangeClassificationCategory?
  @Column(as: RequestTag.RawRepresentation.self)
  public var tags: RequestTag
  public var durationMilliseconds: Int
  public var explanation: String?
  public var createdAt: Date
  public var failure: String?

  public init(
    id: UUIDV7 = UUIDV7(),
    exchangeID: UUIDV7,
    classifierID: String,
    classifierVersion: String,
    usefulness: RequestUsefulness? = nil,
    category: HTTPExchangeClassificationCategory? = nil,
    tags: RequestTag = [],
    durationMilliseconds: Int,
    explanation: String? = nil,
    createdAt: Date = Date(),
    failure: String? = nil
  ) {
    self.id = id
    self.exchangeID = exchangeID
    self.classifierID = classifierID
    self.classifierVersion = classifierVersion
    self.usefulness = usefulness
    self.category = category
    self.tags = tags
    self.durationMilliseconds = durationMilliseconds
    self.explanation = explanation
    self.createdAt = createdAt
    self.failure = failure
  }
}
