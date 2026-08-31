import Hummingbird

struct FixtureEndpointResponse: ResponseCodable {
  let binding: String
  let result: String
}

struct FixtureCapturedExchange: Codable, Sendable {
  let method: String
  let path: String
  let statusCode: Int?
  let outcome: String
  let requestBody: String?
  let requestBodyOmitted: Bool?
  let responseBody: String?
  let responseBodyOmitted: Bool?
  let classification: FixtureCaptureClassification?
}

struct FixtureCaptureClassification: Codable, Sendable {
  let policyVersion: Int
  let category: String
  let ruleID: String
  let tags: [String]
  let requestBodyDisposition: String
  let responseBodyDisposition: String
}

struct FixtureCaptureResponse: ResponseCodable {
  let route: String
  let exchanges: [FixtureCapturedExchange]
}
