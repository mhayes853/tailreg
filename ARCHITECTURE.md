# Architecture: the project multiplexer

**Status:** implemented MUX design. Tailscale binding and CLI process management
are intentionally outside this document.

## 1. Responsibility boundary

A MUX is a long-lived, project-scoped reverse proxy. One MUX owns one project
namespace and can serve any number of apps or processes within that project.
An app is a route in the MUX; it is not another MUX process or listener.

The MUX owns:

- one public ingress listener shared by all of its routes;
- deterministic path-to-route resolution;
- upstream path and forwarding-header policy;
- streaming proxying and HTTP capture;
- persistent route state through a `DatabaseWriter`;
- a loopback-only admin listener for live route mutation and health checks; and
- graceful startup and shutdown of both listeners.

The MUX does not own Tailscale configuration, project discovery, command-line
presentation, or background-process policy. A future CLI can start a MUX and
bind it, but those are callers of this component rather than MUX internals.

## 2. Runtime topology

```text
                           public project path
                                    |
                                    v
                         one MUX ingress listener
                                    |
                    exact first-segment route lookup
                  /web-0            |             /api-0
                    |                |                |
                    v                v                v
              localhost:3000                  localhost:8080

 CLI or supervisor  ---- loopback admin API ---->  MUX route table
                                                        |
                                                        v
                                                 tailreg.sqlite
```

Every MUX has a durable `muxID`. Routes are unique within that ID, so two
projects can both have a `web-0` route without colliding. A MUX may also have
an `externalPathPrefix`, such as `/alpha`, describing the project prefix used
outside the MUX. If that prefix is stripped before ingress, the MUX still uses
it when producing public URLs and `X-Forwarded-Prefix`.

The ingress and admin surfaces are deliberately separate. Public traffic can
only exercise app routes; `status` and route mutation never occupy names in
the public app namespace.

## 3. Route ownership and persistence

The `Multiplexer` accepts GRDB's `DatabaseWriter` directly; there is no route
store, actor, cache, or persistence protocol. Small structured-query helpers
perform transactional reads and mutations against `MuxRouteRecord` and
`MuxInstanceRecord`. Production supplies the shared database pool or queue,
while tests can supply an in-memory writer.

The database has two relevant records:

- `MuxInstanceRecord`: durable MUX identity and external path prefix.
- `MuxRouteRecord`: MUX ID, route slug, upstream URL, path mode, and lifecycle
  timestamps.

On first use, the table creates or loads its MUX instance and hydrates all live
routes. Reusing an ID with a different external prefix is rejected because it
would change every public URL silently. Registration, update, and removal are
persisted before the in-memory snapshot changes. Removal is a soft delete via
`endedAt`, which preserves capture history.

Route names are normalized to URL-safe slugs and receive a stable numeric
suffix (`web-0`, `web-1`, and so on). The live-route uniqueness constraint is
`(muxID, route)`, not global.

Because requests resolve routes from SQLite, committed changes are immediately
visible without an in-process invalidation mechanism. The admin API remains the
live control surface so callers receive validation and the resulting public
route in one operation.

## 4. Live control surface

The admin application binds to loopback independently of ingress and exposes:

| Method | Path | Responsibility |
|---|---|---|
| `GET` | `/status` | process readiness |
| `GET` | `/routes` | list this MUX's live routes |
| `POST` | `/routes` | register another process/app |
| `PUT` | `/routes/:route` | replace its upstream and optionally its path mode |
| `DELETE` | `/routes/:route` | end and remove the route |

This is the seam a future `tailreg up` invocation uses to attach another
process to a MUX that is already running. The API is local control-plane
traffic; it must never be included in the public ingress binding.

## 5. Request routing

Routing is deliberately mechanical:

1. Read the first path segment.
2. Find an exact live route in this MUX.
3. Redirect `/<route>` to the canonical `/<route>/` public URL.
4. Compute the upstream path using the route's path mode.
5. Proxy the request while streaming its body and capture observations.

There is no longest-prefix matching and no reserved ingress path. Unknown
routes return 404 by default.

Each route chooses one of two upstream path modes:

- `strip-route-prefix` (default): `/web-0/assets/app.js` becomes
  `/assets/app.js` upstream.
- `preserve-route-prefix`: `/web-0/assets/app.js` remains
  `/web-0/assets/app.js` upstream.

In both modes, the MUX supplies the complete public prefix, for example
`X-Forwarded-Prefix: /alpha/web-0`, and normal proxy headers. Hop-by-hop and
client-supplied proxy or Tailscale identity headers are not forwarded as
trusted input.

An opt-in `lastSelectedRouteCompatibility` mode can route an otherwise
unmatched root-relative request back to the last explicitly selected route.
It uses a MUX-specific cookie name so project MUXes on one origin cannot
collide. This is best-effort compatibility for apps that emit root-relative
URLs, not the primary routing contract; explicit paths always win.

## 6. Capture isolation

Capture remains in the request data path and streams bounded observations
rather than collecting whole bodies. Exchanges reference route IDs, which in
turn reference a MUX ID. Startup recovery marks only this MUX's incomplete
exchanges as abandoned, so starting one project MUX cannot alter another
project's capture state in the shared database.

Sensitive header values are redacted by default. A generated request ID is
forwarded upstream so later process-level extraction can correlate local logs
with the proxy exchange.

## 7. Lifecycle and failure behavior

`Multiplexer.run()` loads durable routes before accepting traffic, then runs
the admin and ingress applications as one service group. `SIGINT` and
`SIGTERM` initiate graceful shutdown, and the capture recorder is flushed on
both normal and error exits. This supports either foreground execution or a
CLI-managed background child without changing MUX semantics.

| Event | Behavior |
|---|---|
| Unknown route | 404 from ingress |
| Upstream unavailable | 502 and failed capture completion |
| Unsupported protocol upgrade | explicit 501; no accidental HTTP fallback |
| MUX restart | live routes reload from SQLite before listeners run |
| Route removal | persistence is ended, then the in-memory route disappears |
| Reused MUX ID with changed external prefix | startup/load fails explicitly |

## 8. Deferred work

- WebSocket tunneling. The ingress has an explicit upgrade branch, but the
  bidirectional bridge is not implemented yet.
- Response `Location` and `Set-Cookie Path` rewriting for applications that
  require it.
- Authentication beyond the loopback boundary if the admin API ever becomes
  reachable through a non-local transport.
- CLI ownership of PID files, foreground/background behavior, process launch,
  and Tailscale binding reconciliation.

The central invariant is already established: a project consumes one MUX
ingress regardless of how many local apps it contains.
