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
}
