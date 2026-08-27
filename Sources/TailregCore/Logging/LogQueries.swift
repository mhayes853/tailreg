import Foundation
import SQLiteData
import UUIDV7

extension LogRecord.TableColumns {
  public func belongs(to bindingID: UUIDV7) -> some QueryExpression<Bool> {
    self.bindingID.eq(bindingID)
  }

  public func follows(_ cursor: UUIDV7) -> some QueryExpression<Bool> {
    self.id.gt(cursor)
  }
}

extension LogRecord {
  @discardableResult
  public static func append(
    _ lines: [LogLine],
    for bindingID: UUIDV7,
    in db: Database
  ) throws -> Int {
    guard !lines.isEmpty else { return 0 }
    try LogRecord.insert {
      lines.map {
        LogRecord(
          bindingID: bindingID,
          stream: $0.stream,
          message: $0.message,
          at: $0.at
        )
      }
    }
    .execute(db)
    return lines.count
  }

  public static func page(
    for bindingID: UUIDV7,
    after cursor: UUIDV7? = nil,
    limit: Int = 500
  ) -> SelectOf<LogRecord> {
    var query = LogRecord.where { $0.belongs(to: bindingID) }
    if let cursor {
      query = query.where { $0.follows(cursor) }
    }
    return query.order { $0.id }.limit(limit)
  }

  public static func tail(
    for bindingID: UUIDV7,
    limit: Int = 200,
    offset: Int = 0
  ) -> SelectOf<LogRecord> {
    LogRecord
      .where { $0.belongs(to: bindingID) }
      .order { $0.id.desc() }
      .limit(limit)
      .offset(offset)
  }

  @discardableResult
  public static func prune(
    for bindingID: UUIDV7,
    keepingLast count: Int,
    in db: Database
  ) throws -> Int {
    guard count > 0 else {
      try LogRecord.where { $0.belongs(to: bindingID) }.delete().execute(db)
      return db.changesCount
    }
    let cutoff =
      try LogRecord
      .where { $0.belongs(to: bindingID) }
      .order { $0.id.desc() }
      .select { $0.id }
      .limit(1)
      .offset(count - 1)
      .fetchOne(db)
    guard let cutoff else { return 0 }

    try LogRecord
      .where { $0.belongs(to: bindingID) && $0.id.lt(cutoff) }
      .delete()
      .execute(db)
    return db.changesCount
  }

  @discardableResult
  public static func prune(endedBefore date: Date, in db: Database) throws -> Int {
    let cutoff: Date? = date
    try LogRecord
      .where {
        $0.bindingID.in(
          TailscaleBindingRecord
            .where { $0.endedAt.isNot(nil) && $0.endedAt.lt(#bind(cutoff)) }
            .select { $0.id }
        )
      }
      .delete()
      .execute(db)
    return db.changesCount
  }
}
