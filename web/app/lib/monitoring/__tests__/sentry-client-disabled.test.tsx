import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { expect, it, vi } from "vitest"

const loaded = vi.hoisted(() => ({ sdk: false }))
vi.mock("@/app/lib/monitoring/sentry-sdk", () => {
  loaded.sdk = true
  return { init: vi.fn(), captureException: vi.fn(), captureEvent: vi.fn(), captureRouterTransitionStart: vi.fn() }
})
vi.mock("@/app/lib/monitoring/sentry-enabled", () => ({ isSentryEnabled: () => false }))
vi.mock("@/app/lib/web3/schedule-idle", () => ({ scheduleIdle: (run: () => void) => run() }))

it("never downloads the SDK when reporting is off", async () => {
  const { captureException, scheduleSentryLoad } = await import("../sentry-client")
  scheduleSentryLoad()
  window.dispatchEvent(new Event("load"))
  await expect(captureException(new Error("boom"))).resolves.toBeUndefined()
  const { openBugReportForm } = await import("../sentry-client")
  await expect(openBugReportForm("event-1", {} as never)).resolves.toBe(false)
  await new Promise((resolve) => setTimeout(resolve, 0))
  expect(loaded.sdk).toBe(false)
})

it("loads a named-export SDK entry so unused integrations tree-shake away", () => {
  const client = readFileSync(resolve(__dirname, "../sentry-client.ts"), "utf8")
  expect(client).not.toMatch(/import\(["']@sentry\/nextjs["']\)/)
  const sdk = readFileSync(resolve(__dirname, "../sentry-sdk.ts"), "utf8")
  expect(sdk).not.toMatch(/export \*/)
  expect(sdk).toMatch(/export \{[^}]*\binit\b[^}]*\} from "@sentry\/nextjs"/)
})
