# Tailreg

A simple Swift based solution for managing local deployments through a tailnet.

## Package layout

- TailregCore contains Tailscale integration, process/IO primitives, logging,
  request classification/refinement, and the shared SQLite persistence layer.
- TailregMultiplexer contains route registration, HTTP proxying, and capture.
- TailregMultiplexerE2EFixture is a test-only executable used by the browser
  tests.

The command-line executable is planned but is not part of the package yet.

## Tests

Run the Swift tests with `swift test`. The browser suite requires `npm ci`,
`npx playwright install --with-deps chromium`, and `npm run test:e2e`.
