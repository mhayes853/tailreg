import Foundation
import SQLiteData
import UUIDV7

extension HTTPExchangeRecord.TableColumns {
  public func belongs(to routeID: UUIDV7) -> some QueryExpression<Bool> {
    self.routeID.eq(routeID)
  }
}

extension HTTPExchangeRecord {
  public static func page(
    for routeID: UUIDV7,
    before cursor: UUIDV7? = nil,
    limit: Int = 200
  ) -> SelectOf<HTTPExchangeRecord> {
    var query = HTTPExchangeRecord.where { $0.belongs(to: routeID) }
    if let cursor {
      query = query.where { $0.id.lt(cursor) }
    }
    return query.order { $0.id.desc() }.limit(limit)
  }

  @discardableResult
  public static func prune(
    for routeID: UUIDV7,
    keepingLast count: Int,
    in db: Database
  ) throws -> Int {
    guard count > 0 else {
      try HTTPExchangeRecord
        .where { $0.belongs(to: routeID) && $0.completedAt.isNot(nil) }
        .delete()
        .execute(db)
      return db.changesCount
    }
    let cutoff =
      try HTTPExchangeRecord
      .where { $0.belongs(to: routeID) && $0.completedAt.isNot(nil) }
      .order { $0.id.desc() }
      .select { $0.id }
      .limit(1)
      .offset(count - 1)
      .fetchOne(db)
    guard let cutoff else { return 0 }

    try HTTPExchangeRecord
      .where {
        $0.belongs(to: routeID) && $0.completedAt.isNot(nil) && $0.id.lt(cutoff)
      }
      .delete()
      .execute(db)
    return db.changesCount
  }

  @discardableResult
  public static func prune(completedBefore date: Date, in db: Database) throws -> Int {
    let cutoff: Date? = date
    try HTTPExchangeRecord
      .where { $0.completedAt.isNot(nil) && $0.completedAt.lt(#bind(cutoff)) }
      .delete()
      .execute(db)
    return db.changesCount
  }
}
