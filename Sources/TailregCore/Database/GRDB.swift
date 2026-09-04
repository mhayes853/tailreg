import Foundation
import SQLiteData
import UUIDV7

extension TailscaleServeProtocol: QueryBindable, QueryDecodable {}
extension TailscaleBindingStatus: QueryBindable, QueryDecodable {}
extension TailscaleBindingEndReason: QueryBindable, QueryDecodable {}
extension ProcessStream: QueryBindable, QueryDecodable {}
extension HTTPExchangeOutcome: QueryBindable, QueryDecodable {}
extension HTTPExchangeBodyDirection: QueryBindable, QueryDecodable {}
extension MuxRoutePathMode: QueryBindable, QueryDecodable {}
extension ApplicationOwnership: QueryBindable, QueryDecodable {}
extension ProjectExposure: QueryBindable, QueryDecodable {}

@Table("bindings")
public struct TailscaleBindingRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var hostname: String
  public var localPort: Int
  public var tailnetPort: Int
  public var proto: TailscaleServeProtocol
  public var mountPath: String
  public var status: TailscaleBindingStatus
  public var createdAt: Date
  public var endedAt: Date?
  public var endReason: TailscaleBindingEndReason?

  public init(
    id: UUIDV7 = UUIDV7(),
    hostname: String,
    localPort: Int,
    tailnetPort: Int,
    proto: TailscaleServeProtocol,
    mountPath: String,
    status: TailscaleBindingStatus = .pending,
    createdAt: Date,
    endedAt: Date? = nil,
    endReason: TailscaleBindingEndReason? = nil
  ) {
    self.id = id
    self.hostname = hostname
    self.localPort = localPort
    self.tailnetPort = tailnetPort
    self.proto = proto
    self.mountPath = mountPath
    self.status = status
    self.createdAt = createdAt
    self.endedAt = endedAt
    self.endReason = endReason
  }

  public var isLive: Bool { endedAt == nil }

  /// The URL this binding was recorded as serving.
  public var url: URL? {
    tailscaleURL(
      hostname: hostname,
      tailnetPort: tailnetPort,
      proto: proto,
      mountPath: mountPath
    )
  }

  func claims(_ binding: TailscaleBinding) -> Bool {
    binding.tailnetPort == tailnetPort
      && binding.proto == proto
      && binding.mountPath == mountPath
      && binding.localPort == localPort
  }
}

@Table("logs")
public struct LogRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var bindingID: UUIDV7
  public var stream: ProcessStream
  public var message: String
  public var at: Date

  public init(
    id: UUIDV7 = UUIDV7(),
    bindingID: UUIDV7,
    stream: ProcessStream,
    message: String,
    at: Date
  ) {
    self.id = id
    self.bindingID = bindingID
    self.stream = stream
    self.message = message
    self.at = at
  }
}

public enum HTTPExchangeOutcome: String, Codable, Equatable, Sendable {
  case inProgress = "in-progress"
  case complete
  case failed
  case cancelled
  case abandoned
}

public enum HTTPExchangeBodyDirection: String, Codable, Equatable, Sendable {
  case request
  case response
}

@Selection
public struct CapturedHTTPHeader: Codable, Equatable, Hashable, Sendable {
  public var name: String
  public var value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

public enum MuxRoutePathMode: String, Codable, Equatable, Sendable {
  case stripRoutePrefix = "strip-route-prefix"
  case preserveRoutePrefix = "preserve-route-prefix"
}

@Table("muxInstances")
public struct MuxInstanceRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var createdAt: Date
  public var endedAt: Date?

  public init(
    id: UUIDV7 = UUIDV7(),
    createdAt: Date = Date(),
    endedAt: Date? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.endedAt = endedAt
  }
}

@Table("muxRoutes")
public struct MuxRouteRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var muxID: UUIDV7
  public var name: String
  public var route: String
  public var upstreamURL: String
  public var pathMode: MuxRoutePathMode
  public var createdAt: Date
  public var endedAt: Date?

  public init(
    id: UUIDV7 = UUIDV7(),
    muxID: UUIDV7,
    name: String,
    route: String,
    upstreamURL: String,
    pathMode: MuxRoutePathMode = .stripRoutePrefix,
    createdAt: Date,
    endedAt: Date? = nil
  ) {
    self.id = id
    self.muxID = muxID
    self.name = name
    self.route = route
    self.upstreamURL = upstreamURL
    self.pathMode = pathMode
    self.createdAt = createdAt
    self.endedAt = endedAt
  }
}

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

/// How a project runtime was published.
///
/// This is recorded rather than inferred from whether a binding exists. The two states are
/// otherwise indistinguishable after the fact, and a binding that has gone missing is exactly
/// the fault an observing command needs to be able to name.
public enum ProjectExposure: String, Codable, Equatable, Sendable {
  /// Reachable on the tailnet through a root Tailscale binding.
  case tailnet
  /// Reachable only on the MUX's loopback listener.
  case local
}

@Table("muxRuns")
public struct MuxRunRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var projectID: UUIDV7
  public var pid: Int
  public var ingressPort: Int
  public var adminPort: Int
  public var exposure: ProjectExposure
  public var createdAt: Date
  public var endedAt: Date?

  public init(
    id: UUIDV7 = UUIDV7(),
    projectID: UUIDV7,
    pid: Int,
    ingressPort: Int,
    adminPort: Int,
    exposure: ProjectExposure = .tailnet,
    createdAt: Date = Date(),
    endedAt: Date? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.pid = pid
    self.ingressPort = ingressPort
    self.adminPort = adminPort
    self.exposure = exposure
    self.createdAt = createdAt
    self.endedAt = endedAt
  }
}

/// Whether Tailreg launched an application, and may therefore stop it.
///
/// An attached application is someone else's process that Tailreg merely routes to. The
/// distinction is what keeps a lifecycle command from signalling a process it does not own.
public enum ApplicationOwnership: String, Codable, Equatable, Sendable {
  case managed
  case attached
}

/// One run of one application under a project.
///
/// Routes describe what the MUX serves; this describes what Tailreg started and is responsible
/// for stopping. A route cannot carry that on its own: it survives a restart in place, it says
/// nothing about ownership, and an application configured with `expose = false` has no route at
/// all yet still has a process.
@Table("appRuns")
public struct AppRunRecord: Hashable, Sendable {
  public let id: UUIDV7
  public var projectID: UUIDV7
  public var name: String
  public var ownership: ApplicationOwnership
  public var routeID: UUIDV7?
  public var pid: Int?
  public var processGroupID: Int?
  /// Identifies the process behind `pid`, so a recycled PID is never mistaken for this run.
  /// Nil when the start time could not be read, which leaves the run unverifiable rather than
  /// assumed live.
  public var processStartedAt: Int64?
  public var createdAt: Date
  public var endedAt: Date?

  public init(
    id: UUIDV7 = UUIDV7(),
    projectID: UUIDV7,
    name: String,
    ownership: ApplicationOwnership,
    routeID: UUIDV7? = nil,
    pid: Int? = nil,
    processGroupID: Int? = nil,
    processStartedAt: Int64? = nil,
    createdAt: Date = Date(),
    endedAt: Date? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.name = name
    self.ownership = ownership
    self.routeID = routeID
    self.pid = pid
    self.processGroupID = processGroupID
    self.processStartedAt = processStartedAt
    self.createdAt = createdAt
    self.endedAt = endedAt
  }

  public var isLive: Bool { endedAt == nil }
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

public func tailregDatabaseConfiguration() -> Configuration {
  var configuration = Configuration()
  configuration.busyMode = .timeout(5)
  configuration.prepareDatabase { db in
    try db.execute(sql: "PRAGMA journal_mode = WAL")
    try db.execute(sql: "PRAGMA foreign_keys = ON")
  }
  return configuration
}

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
        "id"          TEXT    NOT NULL PRIMARY KEY,
        "projectID"   TEXT    NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE,
        "pid"         INTEGER NOT NULL,
        "ingressPort" INTEGER NOT NULL,
        "adminPort"   INTEGER NOT NULL,
        "exposure"    TEXT    NOT NULL,
        "createdAt"   TEXT    NOT NULL,
        "endedAt"     TEXT,

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

public enum TailregDatabaseKind: Sendable {
  case pool
  case queue
}

public func defaultTailregDatabasePath(
  environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
  let home = environment["HOME"] ?? NSHomeDirectory()
  #if os(macOS)
    return "\(home)/Library/Application Support/tailreg/tailreg.sqlite"
  #else
    let stateHome =
      environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.local/state"
    return "\(stateHome)/tailreg/tailreg.sqlite"
  #endif
}

public func openTailregDatabase(
  path: String = defaultTailregDatabasePath(),
  kind: TailregDatabaseKind = .pool
) throws -> any DatabaseWriter {
  do {
    try createTailregDatabaseDirectory(for: path)
    let writer = try makeTailregDatabaseWriter(kind: kind, path: path)
    try tailregDatabaseMigrator().migrate(writer)
    return writer
  } catch {
    throw TailscaleError.databaseUnavailable(path: path, detail: String(describing: error))
  }
}

private func makeTailregDatabaseWriter(
  kind: TailregDatabaseKind,
  path: String
) throws -> any DatabaseWriter {
  let configuration = tailregDatabaseConfiguration()
  switch kind {
  case .pool: return try DatabasePool(path: path, configuration: configuration)
  case .queue: return try DatabaseQueue(path: path, configuration: configuration)
  }
}

private func createTailregDatabaseDirectory(for path: String) throws {
  let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
  guard !FileManager.default.fileExists(atPath: directory.path) else { return }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}
