import Foundation
import SQLiteData
import UUIDV7

public enum RequestUsefulness: String, Codable, Equatable, Sendable {
  case useful
  case notUseful = "not-useful"
  case uncertain
}

extension RequestUsefulness: QueryBindable, QueryDecodable {}

/// The deliberately small, sanitized application boundary presented to a refiner.
public struct RequestRefinementInput: Equatable, Sendable {
  public let exchangeID: UUIDV7
  public let method: String
  public let path: String
  public let queryNames: [String]
  public let headers: [CapturedHTTPHeader]
  public let heuristicCategory: HTTPExchangeClassificationCategory
  public let heuristicRuleID: String
  public let heuristicTags: RequestTag
  public var bodyByteCount: Int
  public var bodyPreview: String?

  public init(
    exchangeID: UUIDV7,
    method: String,
    path: String,
    queryNames: [String] = [],
    headers: [CapturedHTTPHeader] = [],
    heuristicCategory: HTTPExchangeClassificationCategory,
    heuristicRuleID: String,
    heuristicTags: RequestTag = [],
    bodyByteCount: Int = 0,
    bodyPreview: String? = nil
  ) {
    self.exchangeID = exchangeID
    self.method = method
    self.path = path
    self.queryNames = queryNames
    self.headers = headers
    self.heuristicCategory = heuristicCategory
    self.heuristicRuleID = heuristicRuleID
    self.heuristicTags = heuristicTags
    self.bodyByteCount = bodyByteCount
    self.bodyPreview = bodyPreview
  }
}

/// A model-independent result shared by heuristic and model-backed refinement.
public struct RequestRefinement: Equatable, Sendable {
  public let usefulness: RequestUsefulness
  public let category: HTTPExchangeClassificationCategory
  public let tags: RequestTag
  public let explanation: String?

  public init(
    usefulness: RequestUsefulness,
    category: HTTPExchangeClassificationCategory,
    tags: RequestTag,
    explanation: String? = nil
  ) {
    self.usefulness = usefulness
    self.category = category
    self.tags = tags
    self.explanation = explanation
  }
}

public protocol RequestClassificationRefining: Sendable {
  var classifierID: String { get }
  var classifierVersion: String { get }

  func refine(_ input: RequestRefinementInput) async throws -> RequestRefinement
}
