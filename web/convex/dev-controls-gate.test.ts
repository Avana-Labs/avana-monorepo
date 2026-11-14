// @vitest-environment edge-runtime
//
// P1-1 regression: the sandbox dev-controls guard must FAIL CLOSED in a
// production deployment even when `SANDBOX_DEV_CONTROLS=true`, and stay disabled
// by default. Exercised through `simulateDeficit`, which calls
// `assertSandboxDevControlsEnabled()` before any other work.
import { convexTest } from "convex-test"
import { afterEach, describe, expect, test, vi } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"

const modules = import.meta.glob("./**/*.*s")
const WALLET = `0x${"1".repeat(40)}`

function callSimulateDeficit() {
  const t = convexTest(schema, modules)
  const asUser = t.withIdentity({ subject: WALLET })
  return asUser.mutation(api.sandbox.umbrella.simulateDeficit, {
    wallet: WALLET,
    marketId: "usdc",
    realizedUsd: 100,
  })
}

describe("assertSandboxDevControlsEnabled — production floor (P1-1)", () => {
  afterEach(() => {
    vi.unstubAllEnvs()
  })

  test("fails closed in production even when SANDBOX_DEV_CONTROLS=true", async () => {
    vi.stubEnv("NODE_ENV", "production")
    vi.stubEnv("SANDBOX_DEV_CONTROLS", "true")
    await expect(callSimulateDeficit()).rejects.toThrow("DEV_CONTROLS_DISABLED")
  })

  test("stays disabled by default when the flag is unset", async () => {
    vi.stubEnv("NODE_ENV", "development")
    vi.stubEnv("SANDBOX_DEV_CONTROLS", "")
    await expect(callSimulateDeficit()).rejects.toThrow("DEV_CONTROLS_DISABLED")
  })

  test("unlocks only in a non-production deployment with the flag on", async () => {
    vi.stubEnv("NODE_ENV", "development")
    vi.stubEnv("SANDBOX_DEV_CONTROLS", "true")
    const result = await callSimulateDeficit()
    expect(result.marketId).toBe("usdc")
    expect(result.currentDeficitUsd).toBe(100)
  })
})
