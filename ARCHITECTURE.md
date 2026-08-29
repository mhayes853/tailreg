# Architecture: the multiplexing proxy

**Status:** proposed. None of the multiplexer described here is implemented yet;
this documents the design we intend to build and the reasoning behind the
choices, so they don't have to be re-derived later.

## Motivation

Tailscale serve exposes HTTPS on a node at three ports only — 443, 8443, and
10000 (the set encoded in `TailscaleTailnetPort.autoAllocationPool`). Exposing
more than three local dev servers from one machine therefore requires
multiplexing behind a single port, which means tailreg needs a reverse proxy of
its own.

Once that proxy exists, HTTP traffic capture comes almost free: tailscaled is
otherwise the only process that ever holds the decrypted bytes for a serve
binding, and it exposes nothing per-request. `serve status` is configuration,
tailnet flow logs are netflow-level, audit logs are control-plane, and
`tailscale debug capture` sees ciphertext because tailscaled terminates TLS
itself. Interposing is the only way to get a plaintext HTTP view.

The proxy also yields something tailscale cannot provide from outside the data
path: per-request tailnet identity, via the `Tailscale-User-Login` and
`Tailscale-User-Name` headers that serve injects into proxied requests.

## 1. Shape of the data path

The port is the discriminator. Tailscale does first-level dispatch by path
prefix; the mux never parses a path to decide *whose* request it is.

```
                          tailnet clients
                                |
                                | HTTPS (tailscale-terminated TLS)
                                v
        +-----------------------------------------------+
        |  tailscaled          node.tailnet.ts.net      |
        |  TLS termination . identity . mount table     |
        +-----------------------------------------------+
        |   :443  /web   -->  http://127.0.0.1:9001     |
        |   :443  /api   -->  http://127.0.0.1:9002     |
        |   :443  /docs  -->  http://127.0.0.1:9003     |
        +-----------------------------------------------+
                     |          |          |
            loopback |          |          |
                     v          v          v
        +-----------------------------------------------+
        |  tailreg-mux                    ONE process   |
        |  +----------+----------+----------+           |
        |  |  :9001   |  :9002   |  :9003   |  public   |
        |  |  = /web  |  = /api  |  = /docs | listeners |
        |  +----+-----+----+-----+----+-----+           |
        |       |          |          |                 |
        |    transform . capture . forward              |
        |                                               |
        |  +----------+                                 |
        |  |  :9100   |  admin listener -- 127.0.0.1    |
        |  +----------+  never in any serve mount       |
        +-------+----------+----------+-----------------+
                v          v          v
             :3000      :8080      :4321      dev servers
```

Three properties fall out of this shape, and they are the reason for it:

- A connection on `:9001` is `/web`'s, whatever its path says. There is no
  shared path namespace inside the mux, so route names cannot collide with mux
  internals.
- Each serve mount decodes to a distinct `.localPort(...)`, so
  `TailscaleBindingRecord.claims(_:)` stays a 1:1 match and `reconcile` is
  otherwise untouched.
- Unregistered paths 404 at tailscaled and never reach the mux at all.

The admin listener sits on its own port precisely so that "reachable from the
tailnet" and "can reconfigure the mux" are disjoint sets by construction.

## 2. Processes, targets, and shared state

```
 +--------------------+  POST /routes/{id}/open   +------------------+
 |   tailreg  (CLI)   | ------------------------> |   tailreg-mux    |
 |   short-lived      | <------------------------ |   resident       |
 +---------+----------+      { proxyPort: 9001 }  +---------+--------+
           |                                                |
           | writes: bindings, routes          reads: routes |
           | reads:  logs, exchanges       writes: exchanges |
           v                                                v
   +------------------------------------------------------------+
   |   tailreg.sqlite    WAL . busy timeout 5s . FileLock       |
   +------------------------------------------------------------+
```

Target layout:

| Target | Contains | Depends on |
|---|---|---|
| `TailregCore` | route + exchange models, queries, migrations, tailscale CLI | SQLiteData, UUIDV7, AsyncAlgorithms |
| `TailregMultiplexer` | listeners, proxy engine, transforms, capture, admin API | `TailregCore`, Hummingbird, AsyncHTTPClient |
| `tailreg` (executable) | CLI plus a hidden `mux run` subcommand | both |

Records live in Core so the CLI can query captured traffic without linking
Hummingbird. The Hummingbird dependency moves off the current `Tailreg` target,
which declares it and does not use it. The package has no executable product
today; one binary with a hidden subcommand beats two, because the CLI can then
re-exec its own path rather than locating a sibling binary on `PATH`.

**Cross-process change propagation** is the admin `POST`, because GRDB's
observation is same-process only and SQLite has no cross-process notification
primitive. A low-frequency poll (a few seconds) backs it up so a dropped
notification self-heals rather than wedging.

## 3. Registration

Two-phase, because only the process that binds a socket can claim a port
without a TOCTOU race. If the CLI picked a port by binding-then-closing,
another process could take it in the gap and the mux would fail to bind after
tailscale had already been pointed at it.

```
  CLI              SQLite           mux/admin         tailscaled
   |                  |                 |                  |
 1 | validate slug    |                 |                  |
 2 | preflight -------------------------------------------->|
   |                  |                 |                  |
 3 | insert .pending >|                 |                  |
   |                  |                 |                  |
 4 | open(routeID) --------------------->|                 |
   |                  |            bind :9001              |
   |<---------------- proxyPort 9001 ----|                 |
 5 | persist port --->|                 |                  |
   |                  |                 |                  |
 6 | serve --https=443 --set-path=/web http://...:9001 --->|
 7 | confirm via serve status <-----------------------------|
 8 | activate ------->|                 |                  |
   |                  |                 |                  |
   X any failure -> close(.failed) + POST /routes/{id}/close
```

Steps 2, 6, 7 and 8 are the existing `TailscaleBinder.performBind` flow;
only the port source changes.

Nothing is publicly reachable until step 6, so a crash anywhere in 3-5 leaves
only recoverable debris: `reconcile` already expires `.pending` rows past
`claimGracePeriod` when they never appear in serve status, and the mux drops
listeners for rows that are not live at startup. The `.pending -> .active`
state machine built for the bind race is exactly the right shape here; no new
states are needed.

The mux reports the port and the CLI persists it, since the CLI already owns
the row lifecycle and the file lock.

## 4. Request pipeline

```
   inbound from tailscaled
        |
   +----v--------------------------------------------------+
   | 1  listener --> route          port is the key;       |
   |                                no path matching       |
   +-------------------------------------------------------+
   | 2  request headers                                    |
   |      . drop hop-by-hop (Connection, TE, Trailer,      |
   |        Transfer-Encoding, Upgrade, Proxy-*)           |
   |      . drop client-supplied Tailscale-* then re-add   |
   |        only what arrived via serve                    |
   |      . add X-Forwarded-Proto / -Host / -For           |
   |      . add X-Forwarded-Prefix: /web                   |
   +-------------------------------------------------------+
   | 3  path transform          transparent: pass through  |
   |                            strip:       drop /web     |
   +-------------------------------------------------------+
   | 4  open exchange record    method, path, identity, t0 |
   +----+--------------------------------------------------+
        |
        +--------------> upstream  http://127.0.0.1:3000
        |                                    |
        |<-------------- response head ------+
   +----v--------------------------------------------------+
   | 5  response headers                                   |
   |      . drop hop-by-hop                                |
   |      . strip mode only: rewrite Location,             |
   |        rewrite Set-Cookie Path                        |
   +-------------------------------------------------------+
   | 6  body: stream through, observe bytes                |
   |        NEVER collect() -- SSE and chunked must flow    |
   +-------------------------------------------------------+
   | 7  close record: status, bytes in/out, duration       |
   +----+--------------------------------------------------+
        v
   outbound to tailscaled
```

Notes on the non-obvious steps:

**Step 2, identity.** `Tailscale-User-Login` and friends are only meaningful on
connections that actually came through serve. The loopback listener is
reachable by any local process, so inbound copies must be dropped before
anything downstream reads them. Treat identity as informational, never
authorizational.

**Step 3** is a static per-route transform decided at registration, not a
routing decision. That is what keeps the unresolved `--set-path` strip
semantics (see open questions) a config flip rather than a broken router.

**Step 6** is the constraint that shapes capture: the recorder observes an
async sequence as it passes, accumulating counts. If bodies are ever captured,
it is a bounded prefix with the true size recorded alongside, never a buffer.

**Capture writes** batch by count-or-interval before touching SQLite, reusing
the `chunks(ofCount:or:)` pattern from `ProcessLogMonitor` rather than writing
per request.

**Upstream client** is one shared AsyncHTTPClient with pooling. Short connect
timeout (it is loopback) and no response timeout, since dev servers are slow
and SSE is unbounded.

## 5. Component decomposition

```
 TailregMultiplexer
 |- ListenerSupervisor   binds/unbinds ports, owns listener lifecycle
 |- RouteTable (actor)   listener -> route snapshot, refreshed on reload
 |- ProxyHandler         per-request forward; Hummingbird in, AHC out
 |   |- PathTransform    transparent | strip, per route
 |   |- HeaderPolicy     hop-by-hop, X-Forwarded-*, identity, redaction
 |   \- ResponseRewriter Location + Set-Cookie  (strip mode only)
 |- CaptureRecorder      observe -> batch -> TailregCore
 \- AdminAPI             open / close / reload / status  (loopback)
```

## 6. Failure modes

| Event | Behavior |
|---|---|
| Dev server not listening | 502 with a tailreg page naming the route and expected port, rather than tailscale's generic error |
| Mux crashes | Serve mounts point at dead ports, so requests 502. On restart it reads live bindings and re-binds recorded ports |
| Recorded port stolen after restart | Re-bind elsewhere, rewrite the serve mount, update the row |
| `tailscale serve reset` run by hand | The DB is authoritative; startup reconciliation repairs tailscaled |
| Route unbound | `serve ... off`, close listener, mark `.ended` |

## 7. Route naming and collisions

Route names are a **single path segment** matching `^[a-z0-9][a-z0-9-]*$`,
enforced by a SQLite `CHECK` in the style of the existing schema. No slashes
means no nesting and no longest-prefix subtleties between routes; no dots or
percent-encoding means no traversal games. The existing
`bindings_live_target` unique index on `(tailnetPort, proto, mountPath)`
already gives per-port name uniqueness once `mountPath` is `/<name>`.

Three distinct collision classes, with different resolutions:

1. **Mux control surface vs app paths** - eliminated by putting the admin API
   on its own listener that no serve mount references.
2. **Route vs route** - eliminated by single-segment slugs.
3. **One app's absolute paths landing on another app's mount** - *not*
   fixable in the mux. All routes share one origin, so a hardcoded
   `fetch('/api/users')` from the app at `/web` reaches the app registered at
   `/api`, which may answer it. Mitigations: registered prefixes always beat
   any future heuristic routing, and bind-time warnings on landmine names
   (`api`, `assets`, `static`, `public`, `dist`, `src`, `favicon.ico`,
   `_next`, `graphql`, `health`). Only distinct hostnames genuinely fix it.

## 8. The subpath asset problem

An app that assumes it is mounted at root emits absolute URLs (`/assets/x.js`,
`fetch('/api')`) that do not carry the route prefix. This is the classic
reverse-proxy-under-a-subpath problem, and it is not solvable at the proxy in
general: nginx, Caddy, Apache and Traefik all expose strip/no-strip plus header
rewriting, and all of them document that the rest is the application's job.
Notably, Caddy keeps response-body rewriting out of core and Traefik declines
to do it at all; nginx's `sub_filter` is a string substitution that forces
upstream compression off and corrupts JS string literals that happen to match.

The design therefore has two modes, and a clear primary:

- **Transparent (default, supported).** The app is configured with its base
  path (`vite --base=/web/`, Next `basePath`), the mux forwards the path
  unchanged, and nothing is rewritten. Everything works, including client-side
  URL construction.
- **Strip (compatibility fallback).** The prefix is removed before forwarding;
  `Location` and `Set-Cookie` `Path` are rewritten on the way back. Good for
  APIs and simple server-rendered apps, best-effort for anything else.

Two things make transparent mode practical rather than a documentation burden:

- The mux sends `X-Forwarded-Prefix` alongside the rest of the `X-Forwarded-*`
  set. This is a de-facto convention rather than an RFC (RFC 7239's
  `Forwarded` has no path field; the WSGI world uses `X-Script-Name`), but it
  is honored by many backend frameworks and costs a few header bytes.
- When tailreg supervises the process, it can inject the base path itself,
  since it knows the route name. This matters because JS dev servers do *not*
  honor `X-Forwarded-Prefix` - bundlers bake asset URLs when serving, before
  any header could influence them - so injection is the higher-value lever for
  the primary audience, and the header covers API servers.

## 9. Out of scope for v1

- **WebSockets.** Deferred deliberately. Until then the pipeline has an
  `Upgrade` hole, so HMR-driven dev servers are not usable through the mux.
  Note also that WebSocket handshakes carry `Origin` but not `Referer`, so no
  path-recovery heuristic can ever route them - transparent mode is the only
  viable answer for HMR.
- **Response body rewriting.** We are not reimplementing `sub_filter`. If it
  ever becomes necessary, the defensible version parses HTML (the
  `mod_proxy_html` approach) rather than substituting strings.
- **Referer-based fallback routing for un-prefixed assets.** Under this
  topology there is nowhere for it to live: unregistered paths 404 at
  tailscaled and never reach the mux. Adding it would require a catch-all `/`
  mount, which re-introduces tailreg owning the node root.
- **Request and response body capture.** Metadata plus redacted headers first;
  bodies later, opt-in, size-capped, with `Authorization`/`Cookie`/
  `Set-Cookie` redacted.

## 10. Open questions

- **Does `--set-path=/web` strip the prefix before proxying to the backend?**
  The flag's help text ("Appends the specified path to the base URL for
  accessing the underlying service") hints at stripping, but this needs an
  empirical test against a throwaway mount. It determines whether
  `PathTransform` in transparent mode is the identity or a re-add-prefix, and
  it blocks writing the types.
- **How the mux is started** - autostart on first bind, launchd/systemd user
  service, or explicit - is deliberately unresolved.

## Appendix: rejected alternatives

**Single mux port with path discrimination.** Rejected on a code-level detail:
`ServeConfigDTO.HandlerDTO.target` builds `.localPort` from `URLComponents`,
which reads `.port` and discards the path. So `http://127.0.0.1:9999/web` and
`http://127.0.0.1:9999/api` both decode to `.localPort(9999)`, multiple records
claim the same live serve entry, and `reconcile` goes ambiguous as soon as
there are two routes.

**One serve mount at `/` fronting everything (topology A).** Cleaner internal
model and it would give us the node root for an index page, but it claims the
entire 443 surface, clobbering or being blocked by any existing user serve
config - which `resolveTailnetPort` currently goes out of its way to detect.
It also breaks the 1:1 record-to-serve-entry mapping that reconciliation
depends on. Possible later as an opt-in.

**Passive capture (pcap / eBPF on loopback).** Would see direct-to-localhost
traffic that the proxy cannot, and needs no data-path insertion. Rejected:
requires root, splits into BPF-device on macOS versus AF_PACKET/eBPF on Linux,
demands TCP reassembly and an HTTP parser, and uprobe-based TLS interception
needs per-library symbol resolution that breaks across versions. Far too much
machinery for the delta.

**Tailscale Services (`serve --service`).** Gives each app a distinct hostname
and virtual IP, so every app sits at root and the entire subpath asset problem
evaporates - arguably with better names (`https://web.tailnet.ts.net`) than
paths provide. Not the default because it requires tailnet policy
configuration and service approval, but this is the exit if path rewriting
becomes a recurring support burden.

**Process-level extraction instead of a proxy.** Three tiers, all complements
rather than replacements: parsing the dev server's own stdout access logs is
nearly free but format-dependent and lossy; runtime preload hooks
(`NODE_OPTIONS=--require`) give genuinely richer data (route templates,
handler timings, exceptions) at the cost of per-runtime work; eBPF uprobes see
everything including TLS plaintext but are Linux-only, root-only, and brittle.
The intended composition is the proxy as the portable spine, with a request ID
stamped into the upstream request so process-side signals - including existing
stdout `LogRecord` lines - can be joined back to the proxied exchange.
