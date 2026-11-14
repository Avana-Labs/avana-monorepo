// @vitest-environment edge-runtime

import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api } from "./_generated/api"
import schema from "./schema"
import { seedStarterTestMarkets } from "./starterTestMarkets"

const modules = import.meta.glob("./**/*.*s")
const USERS = 10_000
const EXPECTED_ALLOCATION_USD = 1_000_000
const CONCURRENCY = 16

function wallet(index: number) {
  return `0x${(index + 1).toString(16).padStart(40, "0")}`
}

describe.skipIf(process.env.RUN_ONBOARDING_10K !== "1")("sandbox onboarding — exact 10,000-wallet capacity", () => {
  test("onboards every wallet, grants exactly $1M, and preserves wallet isolation", async () => {
    const t = convexTest(schema, modules)
    await t.run(seedStarterTestMarkets)

    const startedAt = Date.now()
    let onboarded = 0
    let failed = 0
    let allocatedUsd = 0

    for (let start = 0; start < USERS; start += CONCURRENCY) {
      const results = await Promise.all(
        Array.from({ length: Math.min(CONCURRENCY, USERS - start) }, async (_, offset) => {
          const address = wallet(start + offset)
          const asUser = t.withIdentity({ subject: address })
          await asUser.mutation(api.sandbox.onboarding.startAnalysis, { wallet: address })
          return { address, result: await asUser.mutation(api.sandbox.onboarding.claim, { wallet: address }) }
        }),
      )
      for (const { result } of results) {
        if (result.status === "done") {
          onboarded += 1
          allocatedUsd += result.allocatedUsd
        } else {
          failed += 1
        }
      }
      if ((start + results.length) % 1_000 === 0) {
        // eslint-disable-next-line no-console -- long-running capacity lane progress
        console.log("ONBOARDING_10K_PROGRESS", JSON.stringify({ completed: start + results.length, users: USERS }))
      }
    }

    // Deep-read a deterministic cross-section. Exact persistence/cap totals for all
    // 10,000 wallets are asserted below; sampling avoids 40,000 redundant post-claim
    // queries that made this capacity test take longer than an hour serially.
    const sampleIndexes = [0, 1, 99, 100, 999, 1_000, 4_999, 5_000, 9_998, 9_999]
    for (const index of sampleIndexes) {
      const address = wallet(index)
      const asUser = t.withIdentity({ subject: address })
      const [state, onboarding, portfolio, activity] = await Promise.all([
        asUser.query(api.sandbox.transactions.getSessionState, { wallet: address }),
        asUser.query(api.sandbox.onboarding.getWalletOnboardingState, { wallet: address }),
        asUser.query(api.sandbox.transactions.getPortfolio, { wallet: address }),
        asUser.query(api.sandbox.transactions.getActivity, { wallet: address, limit: 200 }),
      ])
      expect(onboarding.profile).toMatchObject({
        wallet: address,
        onboardingStep: "done",
        allocatedUsd: EXPECTED_ALLOCATION_USD,
      })
      expect(portfolio.latest?.totalValueUsd).toBe(EXPECTED_ALLOCATION_USD)
      expect(state.balances.every((row) => row.wallet === address)).toBe(true)
      expect(state.positions.every((row) => row.wallet === address)).toBe(true)
      expect(activity.length).toBeGreaterThan(0)
      if (index > 0) {
        await expect(
          asUser.query(api.sandbox.transactions.getSessionState, { wallet: wallet(index - 1) }),
        ).rejects.toThrow(/WALLET_MISMATCH/)
      }
    }

    const persisted = await t.run(async (ctx) => {
      const [profiles, sessions, allocations, snapshots, economy, shards] = await Promise.all([
        ctx.db.query("sandboxProfiles").collect(),
        ctx.db.query("walletSessions").collect(),
        ctx.db.query("starterAllocations").collect(),
        ctx.db.query("portfolioSnapshots").collect(),
        ctx.db.query("sandboxEconomy").first(),
        ctx.db.query("sandboxEconomyShards").collect(),
      ])
      return {
        profiles: profiles.length,
        sessions: sessions.length,
        allocations: allocations.length,
        snapshots: snapshots.length,
        economyUsers: (economy?.userCount ?? 0) + shards.reduce((sum, shard) => sum + shard.userCount, 0),
        economyGrantedUsd: (economy?.totalGrantedUsd ?? 0) + shards.reduce((sum, shard) => sum + shard.grantedUsd, 0),
      }
    })

    const overflowWallet = wallet(USERS)
    const overflowUser = t.withIdentity({ subject: overflowWallet })
    await overflowUser.mutation(api.sandbox.onboarding.startAnalysis, { wallet: overflowWallet })
    const overflow = await overflowUser.mutation(api.sandbox.onboarding.claim, { wallet: overflowWallet })

    const report = {
      usersAttempted: USERS,
      onboarded,
      failed,
      allocatedUsd,
      persisted,
      overflowStatus: overflow.status,
      durationMs: Date.now() - startedAt,
    }
    // eslint-disable-next-line no-console -- durable load-test report consumed from CI logs
    console.log("ONBOARDING_10K_REPORT", JSON.stringify(report))

    expect(report).toMatchObject({
      usersAttempted: USERS,
      onboarded: USERS,
      failed: 0,
      allocatedUsd: USERS * EXPECTED_ALLOCATION_USD,
      persisted: {
        profiles: USERS,
        sessions: USERS,
        allocations: USERS,
        snapshots: USERS,
        economyUsers: USERS,
        economyGrantedUsd: USERS * EXPECTED_ALLOCATION_USD,
      },
      overflowStatus: "waitlisted",
    })
  }, 3_600_000)
})
