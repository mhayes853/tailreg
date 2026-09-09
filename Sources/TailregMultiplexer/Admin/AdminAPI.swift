import Hummingbird
import TailregCore
import UUIDV7

/// Answered on the admin API. Carries the MUX's identity because admin ports are allocated by
/// probing and can be taken by another MUX in between: a caller has to be able to tell that the
/// port it recorded is still answering for the MUX it recorded.
public struct MultiplexerStatus: ResponseCodable, Equatable, Sendable {
  public let status: String
  public let id: UUIDV7

  public init(status: String, id: UUIDV7) {
    self.status = status
    self.id = id
  }
}

public struct MultiplexerErrorResponse: ResponseCodable, Equatable, Sendable {
  public let error: String
  public let message: String?

  public init(error: String, message: String? = nil) {
    self.error = error
    self.message = message
  }
}

public struct MuxRouteRegistrationRequest: Codable, Equatable, Sendable {
  public let name: String
  public let route: MuxRouteName?
  public let upstreamURL: String
  public let pathMode: MuxRoutePathMode

  public init(
    name: String,
    route: MuxRouteName? = nil,
    upstreamURL: String,
    pathMode: MuxRoutePathMode = .stripRoutePrefix
  ) {
    self.name = name
    self.route = route
    self.upstreamURL = upstreamURL
    self.pathMode = pathMode
  }
}

public struct MuxRouteUpdateRequest: Codable, Equatable, Sendable {
  public let upstreamURL: String
  public let pathMode: MuxRoutePathMode?

  public init(upstreamURL: String, pathMode: MuxRoutePathMode? = nil) {
    self.upstreamURL = upstreamURL
    self.pathMode = pathMode
  }
}

public struct MuxRouteResponse: ResponseCodable, Equatable, Sendable {
  public let id: UUIDV7
  public let muxID: UUIDV7
  public let name: String
  public let route: MuxRouteName
  public let upstreamURL: String
  public let pathMode: MuxRoutePathMode
  public let publicPath: String

  public init(_ binding: MultiplexerBinding) {
    self.id = binding.id
    self.muxID = binding.muxID
    self.name = binding.name
    self.route = binding.route
    self.upstreamURL = binding.upstream.absoluteString
    self.pathMode = binding.pathMode
    self.publicPath = binding.publicPath
  }
}
