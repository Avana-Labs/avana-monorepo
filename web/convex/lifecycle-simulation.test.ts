// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"
import { seedStarterTestMarkets } from "./starterTestMarkets"

// Rooted at the convex directory so convex-test can resolve "sandbox/*".
const modules = import.meta.glob("./**/*.*s")

/**
 * Phase 6 — multi-user lifecycle load harness.
 *
 * Traces the full sandbox lifecycle across N wallets (onboarding claim → a swap action →
 * wallet-scoped reads) and asserts the scaling + isolation invariants the brief calls for:
 *  - criterion A (full lifecycle): every wallet ends `done` with its starter portfolio AND
 *    its post-onboarding action visible in its own session read.
 *  - economy integrity: the shared user counter equals N exactly.
 *  - wallet isolation: a wallet can only read its own state.
 *  - hot-path scaling (#13/S1): the shared starter-catalog singleton is written AT MOST ONCE
 *    across all N claims — never re-patched per claim.
 *  - bounded reads (S6/F1): getSessionState never returns an unbounded transaction list.
 *
 * Default N is small so it runs in normal CI (regression guard, criterion C). Set
 * RUN_LIFECYCLE_SIM_LARGE=1 for a heavier load run.
 */
const N = process.env.RUN_LIFECYCLE_SIM_LARGE === "1" ? 500 : 40
// The in-memory convex-test harness does real DB work per claim, so a large run is slow;
// give it headroom well past vitest's 5s default. The CI-default N stays comfortably fast.
const TEST_TIMEOUT_MS = N > 100 ? 600_000 : 30_000

function wallet(index: number): string {
  return `0x${(index + 1).toString(16).padStart(40, "0")}`
}

describe("Phase 6 — multi-user lifecycle simulation", () => {
  test(
    `onboards ${N} wallets, runs an action each, and holds every scaling invariant`,
    async () => {
      const t = convexTest(schema, modules)
      await t.run(seedStarterTestMarkets)
      await t.run(async (ctx) => {
        const now = Date.now()
        const rows = await ctx.db.query("tokenPrices").collect()
        for (const row of rows) await ctx.db.patch(row._id, { confidence: 0.99, status: "fresh", updatedAt: now })
        // The post-onboarding action swaps usdc <-> eth. seedStarterTestMarkets seeds usdc but not
        // eth, so add a fresh, server-verifiable eth price for the fail-closed swap oracle, which
        // resolves token prices by lowercased symbol.
        await ctx.db.insert("tokenPrices", {
          symbol: "eth",
          llamaId: "test:eth",
          priceUsd: 3000,
          source: "test",
          confidence: 0.99,
          status: "fresh",
          updatedAt: now,
        })
      })

      let catalogUpdatedAtAfterFirstClaim: number | null = null

      for (let index = 0; index < N; index += 1) {
        const address = wallet(index)
        const asUser = t.withIdentity({ subject: address })

        // --- Onboarding lifecycle ---
        await asUser.mutation(api.sandbox.onboarding.startAnalysis, { wallet: address })
        const claimResult = await asUser.mutation(api.sandbox.onboarding.claim, { wallet: address })
        expect(claimResult.status).toBe("done")

        // Hot-path scaling: capture the catalog write-time after the FIRST claim (which seeds it),
        // then assert every subsequent claim leaves it untouched (fast path, #13/S1).
        const [catalog] = await t.run((ctx) =>
          ctx.db
            .query("sandboxStarterCatalog")
            .withIndex("by_singleton", (q) => q.eq("singleton", "starter"))
            .collect(),
        )
        expect(catalog).toBeDefined()
        if (catalogUpdatedAtAfterFirstClaim === null) {
          catalogUpdatedAtAfterFirstClaim = catalog.updatedAt
        } else {
          expect(catalog.updatedAt).toBe(catalogUpdatedAtAfterFirstClaim)
        }

        // --- A post-onboarding action (swap) ---
        const held = await t.run(async (ctx) => {
          const rows = await ctx.db
            .query("walletLiquidBalances")
            .withIndex("by_wallet", (q) => q.eq("wallet", address))
            .collect()
          return rows.find((row) => row.amount > 0)!
        })
        const inputAmount = Math.min(0.25, held.amount / 2)
        const outputAssetId = held.assetId === "usdc" ? "eth" : "usdc"
        const outputSymbol = outputAssetId.toUpperCase()
        const swap = await asUser.mutation(api.sandbox.transactions.recordSwap, {
          wallet: address,
          intentId: `${address}-swap-1`,
          inputAssetId: held.assetId,
          outputAssetId,
          inputSymbol: held.symbol,
          outputSymbol,
          inputAmount,
          outputAmount: 483.5,
          amountUsd: 483.5,
        })
        expect(swap.receipt.status).toBe("success")
        // Idempotency under retry (double-submit / replay) must not double-record.
        const replay = await asUser.mutation(api.sandbox.transactions.recordSwap, {
          wallet: address,
          intentId: `${address}-swap-1`,
          inputAssetId: held.assetId,
          outputAssetId,
          inputSymbol: held.symbol,
          outputSymbol,
          inputAmount,
          outputAmount: 483.5,
          amountUsd: 483.5,
        })
        expect(replay.idempotent).toBe(true)

        // --- Lifecycle read (criterion A): the session reflects onboarding + the action, bounded. ---
        const state = await asUser.query(api.sandbox.transactions.getSessionState, { wallet: address })
        expect(state.positions.length).toBeGreaterThan(0)
        expect(state.positions.every((row) => row.wallet === address)).toBe(true)
        expect(state.transactions.length).toBeLessThanOrEqual(500)
        const swaps = await asUser.query(api.sandbox.transactions.getWalletSwapTransactions, { wallet: address })
        expect(swaps).toHaveLength(1)
      }

      // Economy integrity across the run.
      const economy = await t.withIdentity({ subject: wallet(0) }).query(api.sandbox.onboarding.getEconomyStatus, {
        wallet: wallet(0),
      })
      expect(economy.userCount).toBe(N)

      // Exactly one catalog singleton for the whole run — no duplicate inserts under load.
      const catalogRows = await t.run((ctx) =>
        ctx.db
          .query("sandboxStarterCatalog")
          .withIndex("by_singleton", (q) => q.eq("singleton", "starter"))
          .collect(),
      )
      expect(catalogRows).toHaveLength(1)

      // Wallet isolation: wallet 0 cannot read wallet 1's state.
      await expect(
        t.withIdentity({ subject: wallet(0) }).query(api.sandbox.transactions.getSessionState, { wallet: wallet(1) }),
      ).rejects.toThrow(/WALLET_MISMATCH/)
    },
    TEST_TIMEOUT_MS,
  )
})
