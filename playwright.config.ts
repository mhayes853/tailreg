import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./Tests/Browser",
  fullyParallel: false,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: "http://127.0.0.1:19100",
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
  webServer: [
    {
      command:
        "npm run build --workspace tailreg-e2e-astro && exec node Tests/Fixtures/Astro/dist/server/entry.mjs",
      url: "http://127.0.0.1:19107/",
      reuseExistingServer: false,
      timeout: 120_000,
      env: { HOST: "127.0.0.1", PORT: "19107" },
    },
    {
      command:
        "npm run build --workspace tailreg-e2e-nextjs && exec node node_modules/next/dist/bin/next start Tests/Fixtures/NextJS --hostname 127.0.0.1 --port 19104",
      url: "http://127.0.0.1:19104/",
      reuseExistingServer: false,
      timeout: 120_000,
    },
    {
      command:
        "npm run build --workspace tailreg-e2e-nuxt && exec node Tests/Fixtures/Nuxt/.output/server/index.mjs",
      url: "http://127.0.0.1:19105/",
      reuseExistingServer: false,
      timeout: 120_000,
      env: { PORT: "19105", HOST: "127.0.0.1" },
    },
    {
      command:
        "npm run build --workspace tailreg-e2e-sveltekit && exec node Tests/Fixtures/SvelteKit/build",
      url: "http://127.0.0.1:19103/",
      reuseExistingServer: false,
      timeout: 120_000,
      env: { PORT: "19103", HOST: "127.0.0.1" },
    },
    {
      command:
        "npm run build --workspace tailreg-e2e-tanstack-start && exec node Tests/Fixtures/TanStackStart/.output/server/index.mjs",
      url: "http://127.0.0.1:19108/",
      reuseExistingServer: false,
      timeout: 120_000,
      env: { HOST: "127.0.0.1", PORT: "19108" },
    },
    {
      command:
        "swift build --product TailregMultiplexerE2EFixture && exec .build/debug/TailregMultiplexerE2EFixture",
      url: "http://127.0.0.1:19100/_tailreg/status",
      reuseExistingServer: false,
      timeout: 120_000,
    },
  ],
});
