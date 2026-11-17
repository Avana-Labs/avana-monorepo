import { api } from "@/convex/_generated/api"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { getSiweSession } from "@/app/lib/siwe/auth-store"

/** The redemption rules Convex reports (`feeConfig.redemption`, with defaults): the app never assumes the numbers. */
export type RedemptionRules = { pointsPerStep: number; bpsPerStep: number; days: number; maxBps: number }

export type RedeemOutcome = { ok: true; points: number; bps: number; endsAt: number } | { ok: false }

/**
 * The most steps a wallet can redeem now: what its points pay for, within the cap on the discount it may hold at once.
 * Zero when it cannot redeem.
 */
export function maxRedeemSteps(availablePoints: number, heldBps: number, rules: RedemptionRules): number {
  const byPoints = Math.floor(availablePoints / rules.pointsPerStep)
  const byCap = Math.floor((rules.maxBps - heldBps) / rules.bpsPerStep)
  return Math.max(0, Math.min(byPoints, byCap))
}

/**
 * Spends `steps` steps of points for the temporary fee discount (Convex `wallet.redemptions.redeem`); Convex checks the
 * balance and the cap again. Resolves what was redeemed, or `{ ok: false }` without a session or a deployment and on any
 * refusal or failure, so the dialog can say it did not happen.
 */
export async function redeemPoints(steps: number): Promise<RedeemOutcome> {
  try {
    if (!hasConvexClient) return { ok: false }
    const session = getSiweSession()
    if (!session) return { ok: false }
    const { getSiweConvexClient } = await import("@/app/lib/convex/siwe-convex-provider")
    const client = getSiweConvexClient()
    if (!client) return { ok: false }
    const r = await client.mutation(api.wallet.redemptions.redeem, { wallet: session.wallet, steps })
    return { ok: true, points: r.points, bps: r.bps, endsAt: r.endsAt }
  } catch {
    return { ok: false }
  }
}
