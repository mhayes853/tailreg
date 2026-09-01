import Hummingbird
import SQLiteData
import TailregCore
import TailregMultiplexer

func captureApplication(
  database: any DatabaseWriter,
  recorder: CaptureRecorder,
  port: Int
) -> Application<RouterResponder<BasicRequestContext>> {
  let router = Router()
  router.get("/captures/:route") { _, context in
    let route = try context.parameters.require("route")
    await recorder.flush()

    return try await database.read { db in
      let fetchedRoute =
        try MuxRouteRecord
        .where { $0.route.eq(route) && $0.endedAt.is(nil) }
        .fetchOne(db)
      guard let routeRecord = fetchedRoute else { throw HTTPError(.notFound) }
      let exchanges = try HTTPExchangeRecord.page(for: routeRecord.id, limit: 1_000).fetchAll(db)
      let bodies =
        try HTTPExchangeBodyRecord
        .where { $0.exchangeID.in(exchanges.map(\.id)) }
        .fetchAll(db)
      let classifications =
        try HTTPExchangeClassificationRecord
        .where { $0.exchangeID.in(exchanges.map(\.id)) }
        .fetchAll(db)
      let requestBodiesByExchange = Dictionary(
        uniqueKeysWithValues: bodies.filter { $0.direction == .request }
          .map { ($0.exchangeID, $0) }
      )
      let responseBodiesByExchange = Dictionary(
        uniqueKeysWithValues: bodies.filter { $0.direction == .response }
          .map { ($0.exchangeID, $0) }
      )
      let classificationsByExchange = Dictionary(
        uniqueKeysWithValues: classifications.map { ($0.exchangeID, $0) }
      )
      return FixtureCaptureResponse(
        route: route,
        exchanges: exchanges.map { exchange in
          let requestBody = requestBodiesByExchange[exchange.id]
          let responseBody = responseBodiesByExchange[exchange.id]
          let classification = classificationsByExchange[exchange.id]
          return FixtureCapturedExchange(
            method: exchange.method,
            path: exchange.path,
            statusCode: exchange.statusCode,
            outcome: exchange.outcome.rawValue,
            requestBody: requestBody?.content.map { String(decoding: $0, as: UTF8.self) },
            requestBodyOmitted: requestBody?.omitted,
            responseBody: responseBody?.content.map { String(decoding: $0, as: UTF8.self) },
            responseBodyOmitted: responseBody?.omitted,
            classification: classification.map {
              FixtureCaptureClassification(
                policyVersion: $0.policyVersion,
                category: $0.category.rawValue,
                ruleID: $0.ruleID,
                tags: $0.tags.names,
                requestBodyDisposition: $0.requestBodyDisposition.rawValue,
                responseBodyDisposition: $0.responseBodyDisposition.rawValue
              )
            }
          )
        }
      )
    }
  }

  return Application(
    router: router,
    configuration: ApplicationConfiguration(
      address: .hostname("127.0.0.1", port: port),
      serverName: "tailreg-mux-e2e-capture-admin"
    )
  )
}
