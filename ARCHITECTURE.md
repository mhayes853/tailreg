# Architecture: project lifecycle and multiplexer

**Status:** implemented for `tailreg up`, project-scoped MUX processes, and
root Tailscale bindings.

## 1. Component responsibilities

Tailreg does not require a global daemon. Each CLI invocation opens the shared
GRDB database directly and reconciles the project it was asked to bring up. A
short-lived runtime lock serializes changes that affect MUX processes and local
ports.

The CLI owns:

- project-root and `tailreg.toml` discovery;
- validation and dependency ordering of application specifications;
- durable project and MUX-run identity;
- starting or reusing one MUX process for the project;
- reconciling the project's root Tailscale binding;
- launching or attaching local applications;
- registering stable routes through the MUX's loopback admin API;
- foreground signal handling, background re-execution, and process-group
  supervision; and
- rollback when startup fails partway through.

The MUX owns:

- one public ingress listener shared by every project application;
- exact path-to-route resolution and compatibility routing for root-relative
  application requests;
- upstream path and forwarding-header policy;
- streaming proxying and HTTP capture;
- persistent route state through a GRDB `DatabaseWriter`; and
- a separate loopback-only admin listener for health and route mutation.

Tailscale owns TLS, tailnet identity, and the externally reachable port. It
forwards `/` unchanged to the project MUX. It does not need to distinguish the
applications itself.

## 2. Runtime topology

```text
tailnet host:<project port>  -- serves / -->  project MUX ingress
                                                   |
                              first path segment    |
                              /web                  | /api
                                |                   |
                                v                   v
                         localhost:3000      localhost:8080

tailreg up  -- loopback admin API --> routes
     |                                  |
     +-- launches/supervises apps       +--> tailreg.sqlite
     +-- reconciles Tailscale root binding
```

One project consumes one MUX ingress and one Tailscale port regardless of its
application count. Applications are MUX routes, not MUX instances. Unrelated
projects use separate MUX processes, which keeps their failure and lifecycle
boundaries independent.

Every project has a canonical filesystem root and durable project ID. A live
MUX run records its MUX ID, PID, ingress port, and admin port. Repeated
`tailreg up` invocations verify both the PID and admin health endpoint before
reusing it; stale runtime records are ended and replaced.

## 3. `tailreg up` lifecycle

The command follows one reconciliation path for configured and ad hoc apps:

1. Resolve an explicit `--project`, the nearest ancestor `tailreg.toml`, a Git
   root, or finally the current directory.
2. Parse and validate the TOML desired state, select requested apps, include
   their dependencies, and produce dependency levels.
3. Under the runtime lock, create or reuse the project's MUX and wait for its
   loopback admin endpoint.
4. Reuse or create a Tailscale HTTPS binding from `/` to the MUX ingress. With
   `--local-only`, return the ingress URL without modifying Tailscale.
5. Launch each dependency level concurrently. Each managed command becomes a
   process-group leader and receives `TAILREG_PROJECT_URL`, `TAILREG_APP_PATH`,
   and `TAILREG_PORT` where applicable.
6. Wait for each declared port to listen, then create or update its MUX route.
7. Print the project and application URLs and enter foreground supervision.
8. As managed apps exit, end their routes. When no live routes remain, remove
   the binding and stop the MUX.

Startup is transactional at the invocation boundary: if a later app fails,
Tailreg terminates process groups and removes routes created by that invocation.
It only stops the MUX when the MUX has no routes, so another invocation can
attach applications safely.

`tailreg up --bg` re-executes the same command with standard streams redirected
to a state-directory log. The parent waits for a readiness handshake containing
the resolved URLs before returning. The child then follows the same supervision
and cleanup path as a foreground invocation.

An attached application has no managed process. Its route and the MUX remain
live after `tailreg up` returns because Tailreg does not own that process.

## 4. Project configuration

TOML expresses stable project desired state; command-line flags cover transient
or ad hoc actions. This keeps multi-process startup repeatable without turning
the configuration file into a runtime control protocol.

```toml
[project]
name = "storefront"

[apps.api]
route = "api"
port = 8080
command = ["swift", "run", "API"]

[apps.web]
route = "web"
port = 3000
command = ["npm", "run", "dev"]
working_directory = "frontend"
depends_on = ["api"]

[apps.web.environment]
API_BASE = "/api"
```

An application may specify one command or one loopback `attach` URL. Route,
port, exposure, environment, dependency, working-directory, and path-mode
settings are validated before any processes start. Stable route names must be
unique within a project. If a route is omitted, the MUX allocates a normalized
numeric route such as `web-0`.

## 5. MUX route persistence and control

`Multiplexer` accepts GRDB's `DatabaseWriter` directly. There is no route-store
protocol, actor cache, or persistence abstraction. Structured-query helpers
perform transactional reads and mutations against `MuxInstanceRecord` and
`MuxRouteRecord`. Tests use an in-memory database writer.

Routes are unique within their MUX ID. Registration, update, removal, and
request resolution use SQLite as the source of truth, so separate CLI and MUX
processes do not need an invalidation channel. Removal is a soft delete via
`endedAt`, preserving capture history.

The loopback admin listener is separate from public ingress:

| Method | Path | Responsibility |
|---|---|---|
| `GET` | `/status` | readiness and liveness |
| `GET` | `/routes` | list live routes |
| `POST` | `/routes` | register a process or attached app |
| `PUT` | `/routes/:route` | replace upstream and path mode |
| `DELETE` | `/routes/:route` | end a route |

Public traffic can only exercise application routes. Admin paths never reserve
names in the public namespace.

## 6. Request routing

Routing is mechanical:

1. Read the first path segment.
2. Find an exact live route in this MUX.
3. Redirect `/<route>` to canonical `/<route>/`.
4. Compute the upstream path using the route's path mode.
5. Stream the proxied request and capture bounded observations.

`strip-route-prefix` is the default: `/web/assets/app.js` becomes
`/assets/app.js` upstream. `preserve-route-prefix` keeps the complete path.
The MUX supplies `X-Forwarded-Prefix: /web` and normal sanitized proxy headers.

The project MUX uses `lastSelectedRouteCompatibility` for otherwise unmatched
root-relative requests. Visiting `/web/` selects the web route in a MUX-specific
cookie; a subsequent `/assets/app.js` can therefore return to web, while an
explicit `/api/products` still resolves directly to api. This compatibility
behavior is what allows a single root Tailscale binding to serve typical
frontend/backend projects without rewriting every application asset URL.

## 7. Failure behavior and deferred work

| Event | Behavior |
|---|---|
| Unknown route | 404 from ingress |
| Upstream unavailable | 502 and failed capture completion |
| App exits before its listener is ready | startup fails and invocation changes roll back |
| MUX record has stale PID or health fails | record ends and a replacement MUX starts |
| Ctrl-C or SIGTERM | managed application process groups receive TERM, then KILL after a grace period |
| MUX restart | live routes reload from SQLite before listeners run |
| Unsupported protocol upgrade | explicit 501 |

Deferred commands include explicit `tailreg down`, status/listing, and log
inspection. WebSocket tunneling, response `Location`/cookie-path rewriting, and
non-loopback admin authentication also remain future MUX work.

The central invariant is: one project owns one MUX and one root binding; every
application is a route that can be attached independently.
