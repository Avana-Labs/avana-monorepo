import { defineConfig, devices } from "@playwright/test"

/**
 * Guest (closed-gate) e2e: builds and serves the app with the real SIWE gate, so a visitor with no
 * wallet session sees exactly what production shows. The default config runs the dev open gate,
 * where every visitor counts as signed in and onboarded.
 *
 *   npm run test:e2e:guest
 */
const port = process.env.PLAYWRIGHT_GUEST_PORT ?? "3200"
const baseURL = `http://127.0.0.1:${port}`
process.env.AVANA_GUEST_CLOSED_GATE_E2E = "1"

export default defineConfig({
  testDir: "./tests/e2e",
  testMatch: /guest-browse\.spec\.ts|convex-handshake\.spec\.ts|slow-network-guest\.spec\.ts/,
  timeout: 90_000,
  retries: process.env.CI ? 2 : 0,
  reporter: [["list"]],
  use: { baseURL, trace: "on-first-retry", screenshot: "only-on-failure", ...devices["Desktop Chrome"] },
  webServer: {
    // Production build in its own dist dir; the gate env flags are forced off so `.env.local`'s
    // NEXT_PUBLIC_DEV_OPEN_GATE cannot open it.
    command: `AVANA_NEXT_DIST_DIR=.next-prod NEXT_PUBLIC_DEV_OPEN_GATE=0 NEXT_PUBLIC_PLAYWRIGHT_TEST_MODE=0 sh -c "npm run build && npm run start -- -p ${port}"`,
    url: `${baseURL}/borrow`,
    reuseExistingServer: false,
    timeout: 600_000,
  },
})
