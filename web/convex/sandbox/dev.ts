/**
 * Dev-only sandbox time controls. Every mutation in this file is gated by the
 * shared `assertSandboxDevControlsEnabled` guard (checks
 * `SANDBOX_DEV_CONTROLS === "true"`) so production wallets can never trigger a
 * time-warp. Set `SANDBOX_DEV_CONTROLS=true` in `.env.local` for local dev.
 *
 * `simulateDeficit` / `simulateSlash` live next to `getSessionState` in
 * `./umbrella` so they can reuse the market overlay + slashing helpers; both
 * share this file's `SANDBOX_DEV_CONTROLS` gate via `assertSandboxDevControlsEnabled`.
 */

import { v } from "convex/values"
import { mutation } from "../_generated/server"
import { requireSandboxWallet } from "./auth"
import { assertSandboxDevControlsEnabled } from "./umbrella"

const umbrellaMarketId = v.union(v.literal("gho"), v.literal("usdc"), v.literal("usdt"), v.literal("weth"))

/**
 * Shift a wallet's cooldown/reward clocks backward by `byMs` so the state
 * looks older — the operator can watch a cooldown mature or a reward tranche
 * grow without waiting real wall-clock time. Applies to cooldownStartedAt,
 * cooldownEndsAt, withdrawalWindowEndsAt, and rewardCheckpointAt (the reward
 * accrual clock added by FIX 1). Does NOT touch `lastUpdatedAt` — that would
 * reset the wallet-balance-sync freshness and mask the shift.
 */
export const advanceCooldown = mutation({
  args: { wallet: v.string(), marketId: umbrellaMarketId, byMs: v.number() },
  handler: async (ctx, args) => {
    assertSandboxDevControlsEnabled()
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    if (args.byMs <= 0) return { advanced: 0 }
    const position = await ctx.db
      .query("positions")
      .withIndex("by_wallet_product_market", (q) =>
        q.eq("wallet", wallet).eq("product", "umbrella").eq("marketSlug", args.marketId),
      )
      .unique()
    if (!position) return { advanced: 0 }
    const shift = (value: number | undefined) => (value === undefined ? undefined : value - args.byMs)
    // Shift every active tranche (multi-tranche cooldowns exist since the
    // umbrellaCooldownTranches source of truth landed). Aggregate rollups on
    // the position row (cooldownStartedAt / cooldownEndsAt /
    // withdrawalWindowEndsAt) also get shifted so pre-tranche seed rows +
    // legacy readers stay coherent.
    const tranches = await ctx.db
      .query("umbrellaCooldownTranches")
      .withIndex("by_position", (q) => q.eq("positionId", position._id))
      .collect()
    for (const tranche of tranches) {
      if (tranche.status === "consumed") continue
      await ctx.db.patch(tranche._id, {
        startedAt: tranche.startedAt - args.byMs,
        endsAt: tranche.endsAt - args.byMs,
        windowEndsAt: tranche.windowEndsAt - args.byMs,
        updatedAt: Date.now(),
      })
    }
    await ctx.db.patch(position._id, {
      cooldownStartedAt: shift(position.cooldownStartedAt),
      cooldownEndsAt: shift(position.cooldownEndsAt),
      withdrawalWindowEndsAt: shift(position.withdrawalWindowEndsAt),
      rewardCheckpointAt: shift(position.rewardCheckpointAt),
      revision: (position.revision ?? 0) + 1,
    })
    return { advanced: args.byMs }
  },
})
