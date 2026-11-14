// @vitest-environment edge-runtime
//
// P3-8: `clearPortfolioSnapshots` must apply the same `safeClearLimit` bound that
// `clearWalletEvents` uses, so a caller can't pass an out-of-range (or negative /
// non-integer) batch size through to the internal mutation.
import { convexTest } from "convex-test"
import { afterEach, describe, expect, test, vi } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"

const modules = import.meta.glob("./**/*.*s")
const SECRET = "test-seed-secret"

describe("clearPortfolioSnapshots — clear-limit bound (P3-8)", () => {
  afterEach(() => {
    vi.unstubAllEnvs()
  })

  test("rejects an out-of-range limit", async () => {
    vi.stubEnv("CONVEX_SEED_SECRET", SECRET)
    vi.stubEnv("AVANA_DEPLOYMENT_ENV", "development")
    const t = convexTest(schema, modules)
    await expect(
      t.action(api.seedAdmin.clearPortfolioSnapshots, { seedSecret: SECRET, limit: 10_001 }),
    ).rejects.toThrow(/Invalid clear limit/)
  })

  test("rejects a non-positive / non-integer limit", async () => {
    vi.stubEnv("CONVEX_SEED_SECRET", SECRET)
    vi.stubEnv("AVANA_DEPLOYMENT_ENV", "development")
    const t = convexTest(schema, modules)
    await expect(t.action(api.seedAdmin.clearPortfolioSnapshots, { seedSecret: SECRET, limit: -5 })).rejects.toThrow(
      /Invalid clear limit/,
    )
    await expect(t.action(api.seedAdmin.clearPortfolioSnapshots, { seedSecret: SECRET, limit: 1.5 })).rejects.toThrow(
      /Invalid clear limit/,
    )
  })

  test("still requires the deployment secret", async () => {
    vi.stubEnv("CONVEX_SEED_SECRET", SECRET)
    vi.stubEnv("AVANA_DEPLOYMENT_ENV", "development")
    const t = convexTest(schema, modules)
    await expect(t.action(api.seedAdmin.clearPortfolioSnapshots, { seedSecret: "wrong", limit: 100 })).rejects.toThrow(
      /Unauthorized seed write/,
    )
  })
})
