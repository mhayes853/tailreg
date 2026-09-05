import Foundation
import SQLiteData
import UUIDV7

public func tailregDatabaseMigrator() -> DatabaseMigrator {
  var migrator = DatabaseMigrator()

  migrator.registerMigration("v1: create bindings and logs") { db in
    try #sql(
      """
      CREATE TABLE "bindings" (
        "id"          TEXT    NOT NULL PRIMARY KEY,
        "hostname"    TEXT    NOT NULL,
        "localPort"   INTEGER NOT NULL,
        "tailnetPort" INTEGER NOT NULL,
        "proto"       TEXT    NOT NULL,
        "mountPath"   TEXT    NOT NULL,
        "status"      TEXT    NOT NULL,
        "createdAt"   TEXT    NOT NULL,
        "endedAt"     TEXT,
        "endReason"   TEXT,

        CHECK ("tailnetPort" BETWEEN 1 AND 65535),
        CHECK ("localPort"   BETWEEN 1 AND 65535),
        CHECK ("proto"  IN ('https', 'http', 'tcp', 'tls-terminated-tcp')),
        CHECK ("status" IN ('pending', 'active', 'ended')),
        CHECK ("mountPath" LIKE '/%'),
        CHECK ("endReason" IS NULL OR "endReason" IN ('unbound', 'expired', 'failed')),
        CHECK (("endedAt" IS NULL) = ("endReason" IS NULL)),
        CHECK (("status" = 'ended') = ("endedAt" IS NOT NULL))
      ) STRICT
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE UNIQUE INDEX "bindings_live_target"
        ON "bindings" ("tailnetPort", "proto", "mountPath")
        WHERE "endedAt" IS NULL
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE INDEX "bindings_created_at" ON "bindings" ("createdAt" DESC)
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE TABLE "logs" (
        "id"        TEXT NOT NULL PRIMARY KEY,
        "bindingID" TEXT NOT NULL REFERENCES "bindings"("id") ON DELETE CASCADE,
        "stream"    TEXT NOT NULL,
        "message"   TEXT NOT NULL,
        "at"        TEXT NOT NULL,

        CHECK ("stream" IN ('stdout', 'stderr'))
      ) STRICT
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE INDEX "logs_binding" ON "logs" ("bindingID", "id")
      """
    )
    .execute(db)
  }

  migrator.registerMigration("v2: create mux routes and HTTP exchanges") { db in
    try #sql(
      """
      CREATE TABLE "muxRoutes" (
        "id"          TEXT NOT NULL PRIMARY KEY,
        "name"        TEXT NOT NULL,
        "route"       TEXT NOT NULL,
        "upstreamURL" TEXT NOT NULL,
        "createdAt"   TEXT NOT NULL,
        "endedAt"     TEXT,

        CHECK ("name" <> ''),
        CHECK ("route" <> ''),
        CHECK ("route" GLOB '[a-z0-9]*'),
        CHECK ("route" NOT GLOB '*[^a-z0-9-]*'),
        CHECK ("upstreamURL" <> '')
      ) STRICT
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE UNIQUE INDEX "muxRoutes_live_route"
        ON "muxRoutes" ("route")
        WHERE "endedAt" IS NULL
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE TABLE "httpExchanges" (
        "id"                 TEXT    NOT NULL PRIMARY KEY,
        "routeID"            TEXT    NOT NULL
          REFERENCES "muxRoutes"("id") ON DELETE CASCADE,
        "method"             TEXT    NOT NULL,
        "host"               TEXT,
        "path"               TEXT    NOT NULL,
        "query"              TEXT,
        "requestHeaders"     TEXT    NOT NULL,
        "requestBodyBytes"   INTEGER NOT NULL DEFAULT 0,
        "startedAt"          TEXT    NOT NULL,
        "responseStartedAt"  TEXT,
        "statusCode"         INTEGER,
        "responseHeaders"    TEXT,
        "responseBodyBytes"  INTEGER NOT NULL DEFAULT 0,
        "completedAt"        TEXT,
        "outcome"            TEXT    NOT NULL,
        "failure"            TEXT,
        "tailscaleUserLogin" TEXT,
        "tailscaleUserName"  TEXT,

        CHECK (json_valid("requestHeaders")),
        CHECK ("responseHeaders" IS NULL OR json_valid("responseHeaders")),
        CHECK ("requestBodyBytes" >= 0),
        CHECK ("responseBodyBytes" >= 0),
        CHECK ("statusCode" IS NULL OR "statusCode" BETWEEN 100 AND 599),
        CHECK (
          "outcome" IN ('in-progress', 'complete', 'failed', 'cancelled', 'abandoned')
        ),
        CHECK (("outcome" = 'in-progress') = ("completedAt" IS NULL))
      ) STRICT
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE INDEX "httpExchanges_route"
        ON "httpExchanges" ("routeID", "id" DESC)
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE TABLE "httpExchangeBodies" (
        "exchangeID"        TEXT    NOT NULL
          REFERENCES "httpExchanges"("id") ON DELETE CASCADE,
        "direction"         TEXT    NOT NULL,
        "contentType"       TEXT,
        "content"           BLOB,
        "observedByteCount" INTEGER NOT NULL,
        "omitted"           INTEGER NOT NULL,

        PRIMARY KEY ("exchangeID", "direction"),
        CHECK ("direction" IN ('request', 'response')),
        CHECK ("observedByteCount" >= 0),
        CHECK ("omitted" IN (0, 1)),
        CHECK (("content" IS NULL) = ("omitted" = 1)),
        CHECK ("content" IS NULL OR length("content") <= 1048576),
        CHECK ("content" IS NULL OR length("content") = "observedByteCount"),
        CHECK ("omitted" = 0 OR "observedByteCount" > 1048576)
      ) STRICT
      """
    )
    .execute(db)
  }

  migrator.registerMigration("v3: classify HTTP exchanges") { db in
    try #sql(
      """
      CREATE TABLE "httpExchangeClassifications" (
        "exchangeID"              TEXT    NOT NULL PRIMARY KEY
          REFERENCES "httpExchanges"("id") ON DELETE CASCADE,
        "policyVersion"           INTEGER NOT NULL,
        "category"                TEXT    NOT NULL,
        "ruleID"                  TEXT    NOT NULL,
        "tags"                    INTEGER NOT NULL,
        "requestBodyDisposition"  TEXT    NOT NULL,
        "responseBodyDisposition" TEXT    NOT NULL,

        CHECK ("policyVersion" > 0),
        CHECK ("ruleID" <> ''),
        CHECK ("tags" >= 0),
        CHECK (
          "category" IN (
            'api', 'framework-data', 'document', 'asset',
            'dev-runtime', 'telemetry', 'stream', 'unknown'
          )
        ),
        CHECK (
          "requestBodyDisposition" IN ('retain', 'discard', 'provisional')
        ),
        CHECK (
          "responseBodyDisposition" IN ('retain', 'discard', 'provisional')
        )
      ) STRICT
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE INDEX "httpExchangeClassifications_rule"
        ON "httpExchangeClassifications" (
          "policyVersion", "ruleID", "exchangeID" DESC
        )
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE INDEX "httpExchangeClassifications_category"
        ON "httpExchangeClassifications" ("category", "exchangeID" DESC)
      """
    )
    .execute(db)
  }

  migrator.registerMigration("v4: refine HTTP exchange classifications") { db in
    try #sql(
      """
      CREATE TABLE "httpExchangeClassificationRefinements" (
        "id"                   TEXT    NOT NULL PRIMARY KEY,
        "exchangeID"           TEXT    NOT NULL
          REFERENCES "httpExchanges"("id") ON DELETE CASCADE,
        "classifierID"         TEXT    NOT NULL,
        "classifierVersion"    TEXT    NOT NULL,
        "usefulness"           TEXT,
        "category"             TEXT,
        "tags"                 INTEGER NOT NULL,
        "durationMilliseconds" INTEGER NOT NULL,
        "explanation"          TEXT,
        "createdAt"            TEXT    NOT NULL,
        "failure"              TEXT,

        CHECK ("classifierID" <> ''),
        CHECK ("classifierVersion" <> ''),
        CHECK ("usefulness" IS NULL OR "usefulness" IN ('useful', 'not-useful', 'uncertain')),
        CHECK (
          "category" IS NULL OR "category" IN (
            'api', 'framework-data', 'document', 'asset',
            'dev-runtime', 'telemetry', 'stream', 'unknown'
          )
        ),
        CHECK ("tags" >= 0),
        CHECK ("durationMilliseconds" >= 0),
        CHECK (("failure" IS NULL) = ("usefulness" IS NOT NULL)),
        CHECK (("failure" IS NULL) = ("category" IS NOT NULL))
      ) STRICT
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE INDEX "httpExchangeClassificationRefinements_exchange"
        ON "httpExchangeClassificationRefinements" ("exchangeID", "id")
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE INDEX "httpExchangeClassificationRefinements_classifier"
        ON "httpExchangeClassificationRefinements" (
          "classifierID", "classifierVersion", "id"
        )
      """
    )
    .execute(db)
  }

  migrator.registerMigration("v5: scope routes to MUX instances") { db in
    try #sql(
      """
      CREATE TABLE "muxInstances" (
        "id"        TEXT NOT NULL PRIMARY KEY,
        "createdAt" TEXT NOT NULL,
        "endedAt"   TEXT
      ) STRICT
      """
    )
    .execute(db)

    let legacyMUX = MuxInstanceRecord()
    try MuxInstanceRecord.insert { legacyMUX }.execute(db)

    try #sql(
      """
      ALTER TABLE "muxRoutes"
        ADD COLUMN "muxID" TEXT REFERENCES "muxInstances"("id")
      """
    )
    .execute(db)
    try MuxRouteRecord
      .where { $0.muxID.is(nil) }
      .update { $0.muxID = #bind(legacyMUX.id) }
      .execute(db)

    try #sql(
      """
      ALTER TABLE "muxRoutes"
        ADD COLUMN "pathMode" TEXT NOT NULL DEFAULT 'strip-route-prefix'
        CHECK ("pathMode" IN ('strip-route-prefix', 'preserve-route-prefix'))
      """
    )
    .execute(db)

    try #sql("DROP INDEX \"muxRoutes_live_route\"").execute(db)
    try #sql(
      """
      CREATE UNIQUE INDEX "muxRoutes_live_route"
        ON "muxRoutes" ("muxID", "route")
        WHERE "endedAt" IS NULL
      """
    )
    .execute(db)
    try #sql(
      """
      CREATE INDEX "muxRoutes_mux"
        ON "muxRoutes" ("muxID", "createdAt")
      """
    )
    .execute(db)
  }

  migrator.registerMigration("v6: create project runtimes") { db in
    try #sql(
      """
      CREATE TABLE "projects" (
        "id"        TEXT NOT NULL PRIMARY KEY,
        "rootPath"  TEXT NOT NULL UNIQUE,
        "name"      TEXT NOT NULL,
        "muxID"     TEXT NOT NULL UNIQUE,
        "createdAt" TEXT NOT NULL,

        CHECK ("rootPath" <> ''),
        CHECK ("name" <> '')
      ) STRICT
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE TABLE "muxRuns" (
        "id"               TEXT    NOT NULL PRIMARY KEY,
        "projectID"        TEXT    NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "pid"              INTEGER NOT NULL,
        "processStartedAt" INTEGER,
        "ingressPort"      INTEGER NOT NULL,
        "adminPort"        INTEGER NOT NULL,
        "exposure"         TEXT    NOT NULL,
        "createdAt"        TEXT    NOT NULL,
        "endedAt"          TEXT,

        CHECK ("pid" > 0),
        CHECK ("ingressPort" BETWEEN 1 AND 65535),
        CHECK ("adminPort" BETWEEN 1 AND 65535),
        CHECK ("ingressPort" <> "adminPort"),
        CHECK ("exposure" IN ('tailnet', 'local'))
      ) STRICT
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE UNIQUE INDEX "muxRuns_live_project"
        ON "muxRuns" ("projectID")
        WHERE "endedAt" IS NULL
      """
    )
    .execute(db)
  }

  migrator.registerMigration("v7: record application runs") { db in
    try #sql(
      """
      CREATE TABLE "appRuns" (
        "id"               TEXT    NOT NULL PRIMARY KEY,
        "projectID"        TEXT    NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "name"             TEXT    NOT NULL,
        "ownership"        TEXT    NOT NULL,
        "routeID"          TEXT    REFERENCES "muxRoutes"("id") ON DELETE SET NULL,
        "bindingID"        TEXT    REFERENCES "bindings"("id") ON DELETE SET NULL,
        "pid"              INTEGER,
        "processGroupID"   INTEGER,
        "processStartedAt" INTEGER,
        "createdAt"        TEXT    NOT NULL,
        "endedAt"          TEXT,

        CHECK ("name" <> ''),
        CHECK ("ownership" IN ('managed', 'attached')),
        CHECK ("pid" IS NULL OR "pid" > 0),
        CHECK ("processGroupID" IS NULL OR "processGroupID" > 0),
        -- Only a managed run has a process, and it has both identifiers or neither.
        CHECK (("ownership" = 'managed') OR ("pid" IS NULL AND "processGroupID" IS NULL)),
        CHECK (("pid" IS NULL) = ("processGroupID" IS NULL)),
        CHECK ("processStartedAt" IS NULL OR "pid" IS NOT NULL)
      ) STRICT
      """
    )
    .execute(db)

    // One live run per application makes "the current run" a fact the database enforces, so
    // ending a run is a compare-and-swap rather than a comparison of derived attributes.
    try #sql(
      """
      CREATE UNIQUE INDEX "appRuns_live_application"
        ON "appRuns" ("projectID", "name")
        WHERE "endedAt" IS NULL
      """
    )
    .execute(db)

    try #sql(
      """
      CREATE INDEX "appRuns_project" ON "appRuns" ("projectID", "createdAt")
      """
    )
    .execute(db)
  }

  return migrator
}
