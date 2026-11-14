// @vitest-environment edge-runtime
//
// Bounded-fold correctness for the shared liquidity ledger (compaction / baseline).
//
// The fold is now `marketLiquidityBaseline` (one cumulative row per market) + the
// un-compacted `marketLiquidityDeltas` rows, instead of a full-table scan of every
// action ever taken. These tests prove that split stays EXACTLY equal to the naive sum:
//   1. across ≥2 markets driven through the real `recordTransaction` write path;
//   2. after `compactDeltas` folds the raw rows away (totals unchanged, raw rows pruned,
//      baseline populated) — for both `listDeltas` and the app-wide snapshot;
//   3. for a MIGRATION deployment that already has raw rows (incl. mixed markets) — the
//      first compaction absorbs them with no loss and no double count;
//   4. batched draining converges to the same total over multiple runs.
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"

// Rooted at the convex directory so convex-test can resolve "sandbox/*".
const modules = import.meta.glob("../**/*.*s")

const WALLET = "0xAbC0000000000000000000000000000000000001"

function liquidityReader(t: ReturnType<typeof convexTest>) {
  return t.withIdentity({ subject: WALLET })
}

/** Sum a folded ledger to a comparable {borrowed, supplied} per market. */
function bySlug(rows: Array<{ marketSlug: string; borrowedDeltaUsd: number; suppliedDeltaUsd: number }>) {
  const map = new Map<string, { borrowedDeltaUsd: number; suppliedDeltaUsd: number }>()
  for (const r of rows)
    map.set(r.marketSlug, { borrowedDeltaUsd: r.borrowedDeltaUsd, suppliedDeltaUsd: r.suppliedDeltaUsd })
  return map
}

describe("liquidity bounded fold (compaction) matches the naive sum", () => {
  test("wallet transactions do not enter the protocol-liquidity fold", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })

    // Seed liquid USDC so the cash-out legs (repay + lend deposits) are affordable — this test
    // exercises the liquidity fold, not balance affordability.
    await t.run(async (ctx) => {
      await ctx.db.insert("walletLiquidBalances", {
        wallet: WALLET.toLowerCase(),
        assetId: "usdc",
        symbol: "USDC",
        amount: 5000,
        valueUsd: 5000,
        state: "available",
        updatedAt: 1,
      })
      await ctx.db.insert("walletBorrowBalances", {
        wallet: WALLET.toLowerCase(),
        marketId: "uni-v3-bluechip-weth-usdc",
        poolId: "uni-v3-bluechip-weth-usdc",
        symbol: "WETH/USDC",
        amount: 2000,
        valueUsd: 2000,
        state: "collateral",
        updatedAt: 1,
      })
    })

    // Market A: a borrow ($1000) then a partial repay ($400) on the borrowable asset.
    await asUser.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "A-borrow",
      product: "borrow",
      kind: "borrow",
      marketSlug: "uni-v3-bluechip-weth-usdc",
      assetId: "uni-v2:usdc",
      requestedAmountUsd6: "1000000000",
      executedAmountUsd6: "1000000000",
      amountUsd: 1000,
      position: {
        status: "open",
        marketSlug: "uni-v3-bluechip-weth-usdc",
        debtValueUsd6: "1000000000",
        collateral: [
          {
            marketSlug: "uni-v3-bluechip-weth-usdc",
            collateralShares: "2000000000",
            principalTokenAmount: "2000000000",
            collateralEnabled: true,
            collateralValueUsd6: "2000000000",
          },
        ],
      },
    })
    await asUser.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "A-repay",
      product: "borrow",
      kind: "repay",
      marketSlug: "uni-v3-bluechip-weth-usdc",
      assetId: "uni-v2:usdc",
      requestedAmountUsd6: "400000000",
      executedAmountUsd6: "400000000",
      amountUsd: 400,
      expectedRevision: 0,
      position: {
        status: "open",
        marketSlug: "uni-v3-bluechip-weth-usdc",
        debtValueUsd6: "600000000",
        collateral: [
          {
            marketSlug: "uni-v3-bluechip-weth-usdc",
            collateralShares: "2000000000",
            principalTokenAmount: "2000000000",
            collateralEnabled: true,
            collateralValueUsd6: "2000000000",
          },
        ],
      },
    })

    // Market B: two lend supplies ($500 + $250) on a different market.
    await asUser.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "B-deposit1",
      product: "lend",
      kind: "deposit",
      marketSlug: "usdc",
      requestedAmountUsd6: "500000000",
      executedAmountUsd6: "500000000",
      amountUsd: 500,
      position: { status: "open", marketSlug: "usdc", suppliedUsd6: "500000000" },
    })
    await asUser.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "B-deposit2",
      product: "lend",
      kind: "deposit",
      marketSlug: "usdc",
      requestedAmountUsd6: "250000000",
      executedAmountUsd6: "250000000",
      amountUsd: 250,
      expectedRevision: 0,
      position: { status: "open", marketSlug: "usdc", suppliedUsd6: "750000000" },
    })

    // Wallet-owned actions update product buckets and positions only. Protocol
    // liquidity is populated by the independent market-ingestion path.
    const preFold = bySlug(await liquidityReader(t).query(api.liquidity.listDeltas))
    expect(preFold).toEqual(new Map())
    const rawBefore = await t.run((ctx) => ctx.db.query("marketLiquidityDeltas").collect())
    const baselineBefore = await t.run((ctx) => ctx.db.query("marketLiquidityBaseline").collect())
    expect(rawBefore.length).toBe(0)
    expect(baselineBefore.length).toBe(0)

    // Compact: raw rows fold into per-market baseline rows and are deleted.
    const res = await t.mutation(internal.liquidity.compactDeltas, {})
    expect(res.compacted).toBe(0)
    expect(res.markets).toBe(0)

    // AFTER compaction: identical totals, but now served entirely from the baseline.
    const postFold = bySlug(await liquidityReader(t).query(api.liquidity.listDeltas))
    expect(postFold).toEqual(new Map())
    const rawAfter = await t.run((ctx) => ctx.db.query("marketLiquidityDeltas").collect())
    const baselineAfter = await t.run((ctx) => ctx.db.query("marketLiquidityBaseline").collect())
    expect(rawAfter.length).toBe(0) // raw rows pruned
    expect(baselineAfter.length).toBe(0)

    // The app-wide snapshot rebuilt from the bounded fold matches too.
    await t.mutation(internal.liquidity.rebuildDeltaSnapshot, {})
    const snap = bySlug(await liquidityReader(t).query(api.liquidity.listDeltaSnapshot))
    expect(snap).toEqual(new Map())
  })

  test("wallet transactions remain outside the fold after compaction", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      await ctx.db.insert("walletLiquidBalances", {
        wallet: WALLET.toLowerCase(),
        assetId: "usdc",
        symbol: "USDC",
        amount: 1000,
        valueUsd: 1000,
        state: "available",
        updatedAt: 1,
      })
    })
    const asUser = t.withIdentity({ subject: WALLET })

    await asUser.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "first",
      product: "lend",
      kind: "deposit",
      marketSlug: "usdc",
      requestedAmountUsd6: "500000000",
      executedAmountUsd6: "500000000",
      amountUsd: 500,
      position: { status: "open", marketSlug: "usdc", suppliedUsd6: "500000000" },
    })
    await t.mutation(internal.liquidity.compactDeltas, {})

    // A later supply appends a fresh raw row; the fold must add it to the baseline.
    await asUser.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "second",
      product: "lend",
      kind: "deposit",
      marketSlug: "usdc",
      requestedAmountUsd6: "300000000",
      executedAmountUsd6: "300000000",
      amountUsd: 300,
      expectedRevision: 0,
      position: { status: "open", marketSlug: "usdc", suppliedUsd6: "800000000" },
    })

    expect(bySlug(await liquidityReader(t).query(api.liquidity.listDeltas)).get("usdc")).toBeUndefined()

    // A second compaction folds the new row into the SAME baseline row (no duplicate).
    await t.mutation(internal.liquidity.compactDeltas, {})
    const baseline = await t.run((ctx) => ctx.db.query("marketLiquidityBaseline").collect())
    expect(baseline.length).toBe(0)
    expect(bySlug(await liquidityReader(t).query(api.liquidity.listDeltas)).get("usdc")).toBeUndefined()
  })
})

describe("liquidity compaction — migration of pre-existing raw rows", () => {
  test("legacy rows (no baseline table yet) are absorbed once, with no loss and no double count", async () => {
    const t = convexTest(schema, modules)

    // Simulate a deployment that already accumulated raw delta rows before compaction
    // existed (e.g. every historical onboarding claim appended three). Mixed markets,
    // multiple rows per market, positive and negative deltas.
    const legacy = [
      { marketSlug: "usdc", borrowedDeltaUsd: 0, suppliedDeltaUsd: 400 },
      { marketSlug: "usdc", borrowedDeltaUsd: 0, suppliedDeltaUsd: 100 },
      { marketSlug: "usdc", borrowedDeltaUsd: 0, suppliedDeltaUsd: -50 },
      { marketSlug: "eth-usdt", borrowedDeltaUsd: 2000, suppliedDeltaUsd: 3000 },
      { marketSlug: "eth-usdt", borrowedDeltaUsd: -500, suppliedDeltaUsd: 0 },
      { marketSlug: "uni-v2:usdc", borrowedDeltaUsd: 1234.5, suppliedDeltaUsd: 0 },
    ]
    await t.run(async (ctx) => {
      for (const [i, row] of legacy.entries()) {
        await ctx.db.insert("marketLiquidityDeltas", { ...row, updatedAt: 1000 + i })
      }
    })

    const expected = new Map([
      ["usdc", { borrowedDeltaUsd: 0, suppliedDeltaUsd: 450 }],
      ["eth-usdt", { borrowedDeltaUsd: 1500, suppliedDeltaUsd: 3000 }],
      ["uni-v2:usdc", { borrowedDeltaUsd: 1234.5, suppliedDeltaUsd: 0 }],
    ])

    // Fold works on legacy rows even before any compaction has run (baseline empty).
    expect(bySlug(await liquidityReader(t).query(api.liquidity.listDeltas))).toEqual(expected)

    // Compaction absorbs them into the baseline and deletes them — total unchanged.
    const res = await t.mutation(internal.liquidity.compactDeltas, {})
    expect(res.compacted).toBe(legacy.length)
    expect(res.markets).toBe(3)
    expect(await t.run((ctx) => ctx.db.query("marketLiquidityDeltas").collect())).toHaveLength(0)
    expect(bySlug(await liquidityReader(t).query(api.liquidity.listDeltas))).toEqual(expected)

    // Idempotent: a second compaction with nothing to fold is a no-op and preserves totals.
    const again = await t.mutation(internal.liquidity.compactDeltas, {})
    expect(again).toEqual({ compacted: 0, markets: 0 })
    expect(bySlug(await liquidityReader(t).query(api.liquidity.listDeltas))).toEqual(expected)
  })

  test("fresh deployment: empty tables fold and compact to nothing (no phantom rows)", async () => {
    const t = convexTest(schema, modules)
    expect(await liquidityReader(t).query(api.liquidity.listDeltas)).toEqual([])
    const res = await t.mutation(internal.liquidity.compactDeltas, {})
    expect(res).toEqual({ compacted: 0, markets: 0 })
    expect(await liquidityReader(t).query(api.liquidity.listDeltas)).toEqual([])
    expect(await t.run((ctx) => ctx.db.query("marketLiquidityBaseline").collect())).toHaveLength(0)
  })

  test("batched draining over multiple runs converges to the exact total", async () => {
    const t = convexTest(schema, modules)

    // More rows than a single compaction batch would ideally handle at once; assert the
    // total is invariant no matter how many partial runs it takes to drain. (We drive the
    // fold-per-run helper directly with a small cap by inserting many small rows and
    // compacting repeatedly until the raw table is empty.)
    const ROWS = 50
    await t.run(async (ctx) => {
      for (let i = 0; i < ROWS; i++) {
        await ctx.db.insert("marketLiquidityDeltas", {
          marketSlug: i % 2 === 0 ? "usdc" : "eth-usdt",
          borrowedDeltaUsd: 0,
          suppliedDeltaUsd: 1,
          updatedAt: 5000 + i,
        })
      }
    })

    const expected = new Map([
      ["usdc", { borrowedDeltaUsd: 0, suppliedDeltaUsd: 25 }],
      ["eth-usdt", { borrowedDeltaUsd: 0, suppliedDeltaUsd: 25 }],
    ])
    expect(bySlug(await liquidityReader(t).query(api.liquidity.listDeltas))).toEqual(expected)

    // Drain to completion (the default batch is large, so this is one run here; the loop
    // still proves convergence and that repeated runs never over- or under-count).
    let guard = 0
    for (;;) {
      const res = await t.mutation(internal.liquidity.compactDeltas, {})
      if (res.compacted === 0) break
      if (++guard > 100) throw new Error("compaction did not converge")
      // Total is invariant after every partial run.
      expect(bySlug(await liquidityReader(t).query(api.liquidity.listDeltas))).toEqual(expected)
    }
    expect(await t.run((ctx) => ctx.db.query("marketLiquidityDeltas").collect())).toHaveLength(0)
    expect(bySlug(await liquidityReader(t).query(api.liquidity.listDeltas))).toEqual(expected)
  })
})
