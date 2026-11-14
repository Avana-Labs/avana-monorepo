// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { afterEach, describe, expect, test, vi } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")

afterEach(() => {
  vi.unstubAllEnvs()
})

describe("seed.getCounts is internal-only and bounded", () => {
  test("is registered as internal, not publicly callable", () => {
    // Compile-time proof: getCounts is absent from the public `api` type but present on
    // `internal`. If it were re-registered as a public `query`, the @ts-expect-error would
    // fail to error and the second line would not compile.
    // @ts-expect-error getCounts must not be publicly callable
    void api.seed.getCounts
    expect(internal.seed.getCounts).toBeDefined()
  })

  test("the secret-gated admin action rejects a wrong secret", async () => {
    vi.stubEnv("CONVEX_SEED_SECRET", "s3cret")
    const t = convexTest(schema, modules)
    await expect(t.action(api.seedAdmin.getCounts, { seedSecret: "wrong" })).rejects.toThrow(/Unauthorized/)
  })

  test("counts stay correct: exact for small tables, seeded-signal for large ones", async () => {
    vi.stubEnv("CONVEX_SEED_SECRET", "s3cret")
    vi.stubEnv("AVANA_DEPLOYMENT_ENV", "development")
    vi.stubEnv("VERCEL_ENV", "development")
    const t = convexTest(schema, modules)

    // Empty database → zero counts, nothing seeded.
    const empty = (await t.action(api.seedAdmin.getCounts, { seedSecret: "s3cret" })) as {
      markets: number
      assetMarkets: number
      poolMarkets: number
      allocationSeeded: boolean
      contentSeeded: boolean
    }
    expect(empty.markets).toBe(0)
    expect(empty.allocationSeeded).toBe(false)
    expect(empty.contentSeeded).toBe(false)

    // Seed two markets + one allocation row (a large-table sample).
    const { idsBySlug } = (await t.mutation(internal.seed.upsertMarkets, {
      rows: [
        { scope: "asset", slug: "uni-v2:usdc", chainId: 1, name: "USDC", symbol: "USDC", createdAt: 1 },
        {
          scope: "pool",
          slug: "uni-v3-bluechip-weth-usdc",
          chainId: 1,
          name: "WETH/USDC",
          symbol: "WETH-USDC",
          createdAt: 1,
        },
      ],
    })) as { idsBySlug: Record<string, string> }

    await t.mutation(internal.seed.upsertAllocation, {
      rows: [
        {
          assetId: idsBySlug["uni-v2:usdc"] as never,
          poolId: idsBySlug["uni-v3-bluechip-weth-usdc"] as never,
          day: "2026-07-01",
          valueUsd: 1000,
          sharePct: 100,
          utilizationPct: 50,
          borrowAprPct: 5,
        },
      ],
    })

    const counts = (await t.action(api.seedAdmin.getCounts, { seedSecret: "s3cret" })) as {
      markets: number
      assetMarkets: number
      poolMarkets: number
      allocationSeeded: boolean
    }
    expect(counts.markets).toBe(2)
    expect(counts.assetMarkets).toBe(1)
    expect(counts.poolMarkets).toBe(1)
    expect(counts.allocationSeeded).toBe(true)
  })
})
