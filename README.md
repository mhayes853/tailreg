# Tailreg

A simple Swift based solution for managing local deployments through a tailnet.

## Package layout

- TailregCore contains Tailscale integration, process/IO primitives, logging,
  request classification/refinement, and the shared SQLite persistence layer.
- TailregMultiplexer contains route registration, HTTP proxying, and capture.
- TailregCLI contains project discovery, TOML configuration, MUX reconciliation,
  Tailscale binding, and application supervision.
- `tailreg` is the executable entry point.
- TailregMultiplexerE2EFixture is a test-only executable used by the browser
  tests.

## Bringing up a project

Create `tailreg.toml` at the project root:

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
depends_on = ["api"]
```

Then run all applications in the foreground or background:

```console
tailreg up
tailreg up --bg
```

Pass application names to select part of the configuration (dependencies are
included automatically), or launch and attach ad hoc applications:

```console
tailreg up web
tailreg up --app docs --route docs --port 4321 -- npm run dev
tailreg up --app api --route api --attach http://127.0.0.1:8080
```

Use `--local-only` to exercise the project MUX without changing Tailscale.
Tailreg discovers the nearest `tailreg.toml`, creates or reuses one project MUX,
and attaches every exposed application as a route on that MUX.

Background startup waits up to 60 seconds for readiness by default. Set
`TAILREG_BACKGROUND_STARTUP_TIMEOUT_MS` to a positive millisecond value when a
project needs a different limit.

## Stopping applications

Stop part or all of a project with `down`:

```console
tailreg down          # stop the whole project runtime
tailreg down web      # stop one application, leaving the rest up
```

`down` acts on what is running rather than on `tailreg.toml`, so it stops ad hoc
applications too and never stops an application's dependencies implicitly. Once
the last route is gone it removes the project's Tailscale binding and stops the
MUX. Stopping something already stopped is reported, not an error.

It exits non-zero only when something is still up afterwards. An application that
had to be killed is still down, so it exits zero and reports the problem as a
warning on standard error.

Ctrl-C, or a SIGTERM to Tailreg, sends SIGTERM to each managed application's
process group so the application and its own children stop together. Tailreg
waits up to 5 seconds for each one and escalates to SIGKILL only if it is still
running. Set `TAILREG_STOP_TIMEOUT_MS` to a positive millisecond value to change
that grace period.

Attached applications are never signalled. Tailreg does not own those processes,
so bringing a project down only removes their routes.

## Tests

Run the Swift tests with `swift test`. The browser suite requires `npm ci`,
`npx playwright install --with-deps chromium`, and `npm run test:e2e`.
