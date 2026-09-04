# Architecture: project lifecycle and multiplexer

**Status:** implemented for `tailreg up`, `tailreg down`, project-scoped MUX
processes, and root Tailscale bindings. The remaining command surface is
specified in section 7.

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

## 7. CLI command surface

The public CLI should remain project-oriented. Commands resolve the project in
the same way as `up`, accept `--project` when invoked elsewhere, and open the
shared database directly. Read-only commands do not contact a daemon. Commands
that change a MUX, route, binding, or process take the same short-lived runtime
lock used by `up` and reconcile through the MUX admin API.

| Command | Status | Responsibility |
|---|---|---|
| `tailreg up [APP...]` | Implemented | Reconcile the MUX and root binding, then launch or attach the selected applications and their dependencies. |
| `tailreg down [APP...]` | Implemented | Stop or detach selected applications. With no application names, tear down the complete current project runtime. |
| `tailreg status` | Planned | Show desired and observed state for the current project. `--all` lists every known project. |
| `tailreg logs [APP...]` | Planned | Read or follow retained application output and project-runtime diagnostics. |
| `tailreg requests [APP...]` | Planned | Query captured HTTP exchanges and their heuristic or model-backed classifications. |
| `tailreg request ID` | Planned | Show one captured exchange, including available bodies and classification details. |

### `tailreg down`

`down` is the lifecycle inverse of `up`, but it acts on observed runtime state
rather than re-reading commands from TOML:

- `tailreg down web` removes only `web`; it does not recursively stop the
  dependencies that `up web` selected.
- `tailreg down` removes all routes and Tailreg-owned application processes for
  the current project.
- A managed application receives TERM at its process-group boundary and KILL
  after the existing grace period. An attached application is only detached;
  Tailreg never signals a process it does not own.
- Route removal is conditional on winning a compare-and-swap against the
  application-run record, so an older supervisor cannot remove a newer
  replacement. The route itself cannot carry that condition: `up` updates an
  existing route in place, so a route's identity survives a restart and does not
  distinguish one run from the next.
- A recorded PID is only signalled when the process's start time still matches
  the one recorded with it. These records outlive reboots, and the kernel
  recycles PID numbers.
- Once the final route is gone, the command removes the project's root
  Tailscale binding, stops the MUX, and ends the runtime records.

The operation is idempotent. An application or project that is already down is
reported as such and is not an error, including for ad hoc applications that
`tailreg.toml` never described.

The exit status answers one question: is everything that was selected now down.
An application that had to be killed is still down, so it exits zero and traces
the problem as a warning; a non-zero status means something is still running or
the runtime could not be removed. Diagnostics carry the detail the status
cannot, because an exit code cannot say which application misbehaved.

`down` performs the whole teardown itself rather than leaving part of it to a
running supervisor. It holds the runtime lock across its reconciliation, and a
supervisor blocked on that lock may time out and give up, so nothing else is
guaranteed to finish the work.

A future `--all` option may apply this operation to all projects, but it should
be explicit because it crosses project lifecycle boundaries.

### `tailreg status`

`status` is a read-mostly reconciliation view, not just a database dump. For
each project it combines configured applications, live route records, MUX-run
records, Tailscale bindings, PID liveness, and the MUX health endpoint. The
default human view should show:

- project name, root, and public base URL;
- MUX state and PID;
- each configured or live application, its route and upstream, whether it is
  managed or attached, and its process state; and
- discrepancies such as a stale PID, an unhealthy MUX, a missing binding, or a
  route that is live but no longer configured.

`tailreg status --all` reads every known project. Machine-readable output can
be added as `--json` without creating a separate listing command; a standalone
`tailreg projects` command would duplicate that view.

### `tailreg logs`

`logs` is for process output. With no application names it interleaves the
current project's application streams and prefixes each line with the
application name. Named applications filter the stream. The initial controls
should be `--follow`/`-f`, `--tail N`, and `--since DURATION`; component filters
may expose MUX and Tailscale diagnostics without mixing them into normal output.

Foreground and background execution must write through the same per-application
sink so that log behavior does not depend on how `up` was launched. The current
background invocation log is only a bootstrap diagnostic and is not the durable
interface for this command. Existing `LogRecord` rows belong to Tailscale
bindings, so application output needs its own run-scoped records or durable file
reference rather than overloading that table.

### `tailreg requests` and `tailreg request`

HTTP observation is separate from process logs. `requests` reads captured
exchange summaries from SQLite and filters them by application/route, outcome,
classification, tag, user, or time. `--follow` can poll or observe new database
rows; it does not require a daemon or a control connection to the MUX.

`request ID` renders one exchange with request and response metadata, retained
bodies, the deterministic classification, and any later model-backed
refinement. Querying does not run neural extraction: refinement happens in the
MUX capture pipeline and its result or failure is persisted with the exchange.
Body display should remain bounded and redact sensitive headers by default.

### Commands that should not be public

Attaching is already an `up` mode (`tailreg up --app NAME --attach URL`), not a
separate lifecycle. Direct route mutation is an implementation detail of
`up`/`down`, and direct MUX start/stop commands would let users violate the
one-project/one-MUX invariant. Two hidden commands remain valid implementation
details:

- `_mux-run` is the child entry point for one project MUX.
- `_exec` creates an application process group and replaces itself with the
  configured executable.

### Persistence needed by the remaining lifecycle commands

`ProjectRecord`, `MuxRunRecord`, and `MuxRouteRecord` describe the project and
MUX, but they do not durably describe application process ownership. Before
`down`, application-aware `status`, and durable `logs` are implemented, add an
application-run record containing at least:

- project and route identity;
- application name and managed-versus-attached ownership;
- PID and process-group ID for managed processes;
- creation, readiness, exit, and end state; and
- the application log location or relation.

The CLI writes this record before publishing the route and ends it during
normal exit, rollback, or `down`. As with routes, structured GRDB queries are
enough; no store protocol, actor cache, or global daemon is required.

## 8. Failure behavior and deferred work

| Event | Behavior |
|---|---|
| Unknown route | 404 from ingress |
| Upstream unavailable | 502 and failed capture completion |
| App exits before its listener is ready | startup fails and invocation changes roll back |
| MUX record has stale PID or health fails | record ends and a replacement MUX starts |
| Ctrl-C or SIGTERM | managed application process groups receive TERM, then KILL after a grace period |
| MUX restart | live routes reload from SQLite before listeners run |
| Unsupported protocol upgrade | explicit 501 |

The commands in section 7 remain implementation work. WebSocket tunneling,
response `Location`/cookie-path rewriting, and non-loopback admin authentication
also remain future MUX work.

The central invariant is: one project owns one MUX and one root binding; every
application is a route that can be attached independently.
