import Foundation
import SQLiteData
import UUIDV7

@Table("projects")
public struct ProjectRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var rootPath: String
  public var name: String
  public var muxID: UUIDV7
  public var createdAt: Date

  public init(
    id: UUIDV7 = UUIDV7(),
    rootPath: String,
    name: String,
    muxID: UUIDV7 = UUIDV7(),
    createdAt: Date = Date()
  ) {
    self.id = id
    self.rootPath = rootPath
    self.name = name
    self.muxID = muxID
    self.createdAt = createdAt
  }
}
