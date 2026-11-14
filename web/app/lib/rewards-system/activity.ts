import type { PortfolioActivityRow } from "@/app/lib/data/providers/portfolio"
import type { RewardClaim, RewardTask } from "@/app/lib/rewards-engine"

/**
 * Map gamification reward claims into portfolio activity rows so a claimed AVA
 * reward shows up on the dashboard Activity tab alongside borrow/lend/multiply
 * actions. Without this, claims only ever lived in the separate RewardsSessionState
 * and never reached the activity ledger.
 *
 * AVA is a points balance with no USD price, so the numeric amount is carried
 * as-is and RecentActivity renders it with an "AVA" suffix (not "$").
 */
export function buildRewardsActivityHistory(
  walletId: string,
  claims: RewardClaim[],
  tasks: RewardTask[] = [],
): PortfolioActivityRow[] {
  const taskTitleById = new Map(tasks.map((task) => [task.id, task.title]))
  return claims
    .filter((claim) => claim.wallet === walletId)
    .map((claim) => ({
      id: claim.claimId,
      at: new Date(claim.claimedAt).toISOString(),
      product: "rewards" as const,
      kind: "claim" as const,
      status: claim.status === "confirmed" ? ("confirmed" as const) : ("pending" as const),
      amountUsd: claim.amount,
      primaryLabel: taskTitleById.get(claim.taskId) ?? "Avana rewards",
      secondaryLabel: `${claim.amount} ${claim.rewardSymbol} claimed`,
      txHash: claim.syntheticTxHash,
    }))
}
