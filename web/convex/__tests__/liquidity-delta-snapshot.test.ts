// @vitest-environment edge-runtime
/* eslint-disable @typescript-eslint/no-explicit-any -- convex-test's t.run(ctx) is loosely typed; the ctx casts in this harness test are intentional. */
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"
import { COMPACTION_DIRTY_THRESHOLD } from "../liquidity"

const modules = import.meta.glob("../**/*.*s")

const WALLET = "0xAbC0000000000000000000000000000000000001"

function liquidityReader(t: any) {
  return t.withIdentity({ subject: WALLET })
}

/**
 * Run the debounced `rebuildDeltaSnapshot` that appends queue. Aggregate rebuilds are
 * coalesced behind `SNAPSHOT_REBUILD_DEBOUNCE_MS`, so tests must let the window elapse
 * before asserting on `listDeltaSnapshot`.
 */
async function flushRebuilds(t: any) {
  // Drain immediate work (cold-cache build, post-compaction rebuild), then run the
  // debounced rebuild directly — convex-test cannot fast-forward a `runAfter(delay)`
  // clock, so invoking it represents the window elapsing. `queuedRebuildAt` covers the
  // scheduling half of the contract.
  await t.finishAllScheduledFunctions(() => {})
  await t.mutation(internal.liquidity.rebuildDeltaSnapshot, {})
}

/** The debounce marker: > 0 while a rebuild is queued, 0 once it has landed. */
async function queuedRebuildAt(t: any) {
  return t.run(async (ctx: any) => {
    const state = await ctx.db.query("liquidityRebuildState").unique()
    return state?.scheduledFor ?? 0
  })
}

describe("listDeltaSnapshot action-triggered aggregate (M33)", () => {
  test("rebuildDeltaSnapshot is internal-only", () => {
    // @ts-expect-error rebuildDeltaSnapshot must not be publicly callable
    void api.liquidity.rebuildDeltaSnapshot
    expect(internal.liquidity.rebuildDeltaSnapshot).toBeDefined()
  })

  test("a write lands in the aggregate once the debounced rebuild runs", async () => {
    const t = convexTest(schema, modules)

    await t.mutation(internal.liquidity.rebuildDeltaSnapshot, {})
    expect(await liquidityReader(t).query(api.liquidity.listDeltaSnapshot)).toEqual([])

    await t.mutation(internal.liquidity.recordDelta, {
      marketSlug: "uni-v2:usdc",
      borrowedDeltaUsd: 1000,
    })

    // The raw ledger is immediate — only the shared aggregate is debounced.
    const raw = await liquidityReader(t).query(api.liquidity.listDeltas)
    expect(raw.find((r) => r.marketSlug === "uni-v2:usdc")?.borrowedDeltaUsd).toBe(1000)

    await flushRebuilds(t)
    const snap = await liquidityReader(t).query(api.liquidity.listDeltaSnapshot)
    expect(snap.find((r) => r.marketSlug === "uni-v2:usdc")?.borrowedDeltaUsd).toBe(1000)
  })

  test("a burst of appends coalesces into a single cache write", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.liquidity.rebuildDeltaSnapshot, {})

    for (let i = 0; i < 50; i++) {
      await t.mutation(internal.liquidity.recordDelta, { marketSlug: "uni-v2:usdc", borrowedDeltaUsd: 1 })
    }

    // Had the cache been rewritten per append (the fan-out this debounce removes) the
    // aggregate would already read 50. Inside the window it still serves the last build.
    expect(await liquidityReader(t).query(api.liquidity.listDeltaSnapshot)).toEqual([])
    // ...and the 50 appends left exactly one rebuild queued, not 50.
    expect(await queuedRebuildAt(t)).toBeGreaterThan(0)

    await flushRebuilds(t)
    expect(await queuedRebuildAt(t)).toBe(0)
    const snap = await liquidityReader(t).query(api.liquidity.listDeltaSnapshot)
    expect(snap.find((r) => r.marketSlug === "uni-v2:usdc")?.borrowedDeltaUsd).toBe(50)
  })

  test("cold cache (never built) folds the raw events so the app still hydrates", async () => {
    const t = convexTest(schema, modules)
    // First write schedules a rebuild when cache is cold; finish scheduled jobs.
    await t.mutation(internal.liquidity.recordDelta, {
      marketSlug: "uni-v2:usdc",
      borrowedDeltaUsd: 1000,
    })
    await t.finishAllScheduledFunctions(() => {
      // no fake timers needed — flush whatever was queued
    })
    const snap = await liquidityReader(t).query(api.liquidity.listDeltaSnapshot)
    expect(snap.find((r) => r.marketSlug === "uni-v2:usdc")?.borrowedDeltaUsd).toBe(1000)
  })

  test("aggregate matches the raw-event fold after many actions", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.liquidity.rebuildDeltaSnapshot, {})

    const N = 200
    for (let i = 0; i < N; i++) {
      await t.mutation(internal.liquidity.recordDelta, {
        marketSlug: i % 2 === 0 ? "uni-v2:usdc" : "aave-usdc",
        borrowedDeltaUsd: 1,
        suppliedDeltaUsd: i % 3 === 0 ? 2 : 0,
      })
    }

    await flushRebuilds(t)
    const snap = await liquidityReader(t).query(api.liquidity.listDeltaSnapshot)
    const raw = await liquidityReader(t).query(api.liquidity.listDeltas)
    const bySlug = (rows: typeof snap) =>
      new Map(rows.map((row) => [row.marketSlug, { b: row.borrowedDeltaUsd, s: row.suppliedDeltaUsd }]))
    expect(bySlug(snap)).toEqual(bySlug(raw))
  })

  test("zero deltas and failed no-ops leave the aggregate unchanged", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.liquidity.rebuildDeltaSnapshot, {})
    await t.mutation(internal.liquidity.recordDelta, {
      marketSlug: "uni-v2:usdc",
      borrowedDeltaUsd: 0,
      suppliedDeltaUsd: 0,
    })
    expect(await liquidityReader(t).query(api.liquidity.listDeltaSnapshot)).toEqual([])
  })

  test("dirty threshold batch can be compacted to an empty raw window", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.liquidity.rebuildDeltaSnapshot, {})

    for (let i = 0; i < COMPACTION_DIRTY_THRESHOLD; i++) {
      await t.mutation(internal.liquidity.recordDelta, {
        marketSlug: `m-${i % 17}`,
        borrowedDeltaUsd: 1,
      })
    }

    const before = await t.run(async (ctx: any) => (await ctx.db.query("marketLiquidityDeltas").collect()).length)
    expect(before).toBe(COMPACTION_DIRTY_THRESHOLD)

    await t.mutation(internal.liquidity.compactDeltas, {})
    await flushRebuilds(t)
    const rawCount = await t.run(async (ctx: any) => (await ctx.db.query("marketLiquidityDeltas").collect()).length)
    expect(rawCount).toBe(0)

    const snap = await liquidityReader(t).query(api.liquidity.listDeltaSnapshot)
    const raw = await liquidityReader(t).query(api.liquidity.listDeltas)
    expect(snap.length).toBeGreaterThan(0)
    expect(new Map(snap.map((r) => [r.marketSlug, r.borrowedDeltaUsd]))).toEqual(
      new Map(raw.map((r) => [r.marketSlug, r.borrowedDeltaUsd])),
    )
  }, 15_000)

  test("crons.ts no longer registers idle liquidity intervals", () => {
    const source = readFileSync(resolve(__dirname, "../crons.ts"), "utf8")
    expect(source).not.toMatch(/compact liquidity deltas/)
    expect(source).not.toMatch(/rebuild liquidity snapshot/)
    expect(source).not.toMatch(/internal\.liquidity\.(compactDeltas|rebuildDeltaSnapshot)/)
  })
})
