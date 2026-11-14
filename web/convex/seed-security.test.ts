// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { afterEach, describe, expect, test, vi } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"

const modules = import.meta.glob("./**/*.*s")

describe("seed administration", () => {
  test("rejects seed actions without the deployment secret", async () => {
    const t = convexTest(schema, modules)

    await expect(
      t.action(api.seedAdmin.upsertMarkets, {
        seedSecret: "not-the-deployment-secret",
        rows: [],
      }),
    ).rejects.toThrow("Unauthorized seed write")
  })
})

afterEach(() => vi.unstubAllEnvs())
test("production seed administration denies even a valid secret", async () => {
  vi.stubEnv("CONVEX_SEED_SECRET", "test-only")
  vi.stubEnv("AVANA_DEPLOYMENT_ENV", "production")
  const t = convexTest(schema, modules)
  await expect(t.action(api.seedAdmin.upsertMarkets, { seedSecret: "test-only", rows: [] })).rejects.toThrow(
    "Seed administration is disabled",
  )
})
