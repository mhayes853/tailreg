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
  webServer: {
    command:
      "swift build --product TailregMultiplexerE2EFixture && exec .build/debug/TailregMultiplexerE2EFixture",
    url: "http://127.0.0.1:19100/_tailreg/status",
    reuseExistingServer: false,
    timeout: 120_000,
  },
});
