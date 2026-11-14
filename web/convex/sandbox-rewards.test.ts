// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"
import { deriveClaimAmountUsd } from "./sandbox/rewards_catalog"

const modules = import.meta.glob("./**/*.*s")
const WALLET = "0xAbC0000000000000000000000000000000000001"
const OTHER = "0xAbC0000000000000000000000000000000000002"

describe("sandbox rewards state", () => {
  test("persists and rehydrates only for the authenticated owner", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await asUser.mutation(api.sandbox.rewards.saveState, {
      wallet: WALLET,
      stateJson: JSON.stringify({ events: [], claims: [] }),
    })

    const state = await asUser.query(api.sandbox.rewards.getState, { wallet: WALLET })
    expect(JSON.parse(state?.stateJson ?? "{}")).toEqual({ events: [], claims: [] })

    await expect(
      t.withIdentity({ subject: OTHER }).query(api.sandbox.rewards.getState, { wallet: WALLET }),
    ).rejects.toThrow(/WALLET_MISMATCH/)
  })

  test("rejects malformed state without creating a row", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.rewards.saveState, { wallet: WALLET, stateJson: "not-json" }),
    ).rejects.toThrow(/INVALID_REWARDS_STATE/)
    expect(await asUser.query(api.sandbox.rewards.getState, { wallet: WALLET })).toBeNull()
  })

  test("rejects structurally invalid state and forged claims", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.rewards.saveState, { wallet: WALLET, stateJson: JSON.stringify({}) }),
    ).rejects.toThrow(/INVALID_REWARDS_STATE/)
    await expect(
      asUser.mutation(api.sandbox.rewards.saveState, {
        wallet: WALLET,
        stateJson: JSON.stringify({
          events: [],
          claims: [
            {
              claimId: "forged",
              wallet: WALLET,
              taskId: "connect-wallet",
              amount: 1_000_000,
              rewardSymbol: "AVA",
              status: "confirmed",
              syntheticTxHash: "forged-hash",
              claimedAt: 1,
            },
          ],
        }),
      }),
    ).rejects.toThrow(/INVALID_REWARDS_STATE/)
    expect(await asUser.query(api.sandbox.rewards.getState, { wallet: WALLET })).toBeNull()
  })

  test("accepts a correctly-valued claim only after its authoritative transaction", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    const claim = {
      claimId: "claim-connect-wallet",
      wallet: WALLET,
      taskId: "connect-wallet",
      amount: 25,
      rewardSymbol: "AVA",
      status: "confirmed",
      syntheticTxHash: "sim-connect-wallet",
      claimedAt: 1,
    }
    await expect(
      asUser.mutation(api.sandbox.rewards.saveState, {
        wallet: WALLET,
        stateJson: JSON.stringify({ events: [], claims: [claim] }),
      }),
    ).rejects.toThrow(/UNAUTHORIZED_REWARD_CLAIM/)

    await asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
      wallet: WALLET,
      intentId: "rewards:connect-wallet",
      taskIds: ["connect-wallet"],
      syntheticTxHash: "sim-connect-wallet",
    })
    await expect(
      asUser.mutation(api.sandbox.rewards.saveState, {
        wallet: WALLET,
        stateJson: JSON.stringify({ events: [], claims: [claim] }),
      }),
    ).resolves.toMatchObject({ revision: 0, stale: false })
  })

  // saveState only re-verifies claims that are not already in the stored row (re-checking
  // them re-read up to 500 transactions on every save). That trust must not extend to a
  // claim the caller is adding for the first time.
  test("a new forged claim is rejected even when the stored row already holds a valid one", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    const authorized = {
      claimId: "claim-connect-wallet",
      wallet: WALLET,
      taskId: "connect-wallet",
      amount: 25,
      rewardSymbol: "AVA",
      status: "confirmed",
      syntheticTxHash: "sim-connect-wallet",
      claimedAt: 1,
    }

    await asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
      wallet: WALLET,
      intentId: "rewards:connect-wallet",
      taskIds: ["connect-wallet"],
      syntheticTxHash: "sim-connect-wallet",
    })
    const saved = await asUser.mutation(api.sandbox.rewards.saveState, {
      wallet: WALLET,
      stateJson: JSON.stringify({ events: [], claims: [authorized] }),
    })

    // Same stored claim (trusted, no transaction re-scan) plus one with no transaction.
    // Valued correctly for its task so it clears validation and reaches the auth check.
    const forgedTaskId = "first-lend-deposit"
    const forged = {
      ...authorized,
      claimId: "claim-first-lend-deposit",
      taskId: forgedTaskId,
      amount: deriveClaimAmountUsd([forgedTaskId]),
    }
    await expect(
      asUser.mutation(api.sandbox.rewards.saveState, {
        wallet: WALLET,
        stateJson: JSON.stringify({ events: [], claims: [authorized, forged] }),
      }),
    ).rejects.toThrow(/UNAUTHORIZED_REWARD_CLAIM/)

    // Re-saving only the already-persisted claim still succeeds.
    await expect(
      asUser.mutation(api.sandbox.rewards.saveState, {
        wallet: WALLET,
        stateJson: JSON.stringify({ events: [], claims: [authorized] }),
        expectedRevision: saved.revision,
      }),
    ).resolves.toMatchObject({ stale: false })
  })

  // The transaction scan is capped at the 500 most recent rows, so an active wallet
  // eventually pushes an old claim's authorising transaction out of the window. Re-verifying
  // every claim on every save therefore used to lock that wallet out of saving at all. Only
  // verifying newly-added claims removes both the repeated read and that failure.
  test("an already-persisted claim survives its authorising transaction leaving the window", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    const taskId = "connect-wallet"
    const claim = {
      claimId: "claim-connect-wallet",
      wallet: WALLET,
      taskId,
      amount: deriveClaimAmountUsd([taskId]),
      rewardSymbol: "AVA",
      status: "confirmed",
      syntheticTxHash: "sim-connect-wallet",
      claimedAt: 1,
    }

    await asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
      wallet: WALLET,
      intentId: "rewards:connect-wallet",
      taskIds: [taskId],
      syntheticTxHash: "sim-connect-wallet",
    })
    const saved = await asUser.mutation(api.sandbox.rewards.saveState, {
      wallet: WALLET,
      stateJson: JSON.stringify({ events: [], claims: [claim] }),
    })

    // Stand in for the transaction scrolling past the 500-row cap.
    await t.run(async (ctx) => {
      for (const row of await ctx.db.query("transactions").collect()) {
        if (row.product === "rewards") await ctx.db.delete(row._id)
      }
    })

    await expect(
      asUser.mutation(api.sandbox.rewards.saveState, {
        wallet: WALLET,
        stateJson: JSON.stringify({ events: [], claims: [claim] }),
        expectedRevision: saved.revision,
      }),
    ).resolves.toMatchObject({ stale: false })
  })
})
