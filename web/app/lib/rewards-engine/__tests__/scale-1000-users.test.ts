import { describe, expect, it } from "vitest"
import { buildDefaultRewardsCatalog, calculateRewardSummary, evaluateAllTasksForUser } from "@/app/lib/rewards-engine"
import { makeStressRewardEvents } from "./stress-fixtures"

describe("rewards engine 1000-wallet scale", () => {
  it(
    "evaluates 1000 concurrent wallet timelines deterministically and keeps summaries finite",
    { timeout: 30_000 },
    () => {
      const now = Date.UTC(2026, 5, 19)
      const tasks = buildDefaultRewardsCatalog(now)
      const events = makeStressRewardEvents(1_000, now - 21 * 24 * 60 * 60 * 1000)

      const sampledWallets = [
        "wallet-rewards-stress-0",
        "wallet-rewards-stress-7",
        "wallet-rewards-stress-250",
        "wallet-rewards-stress-500",
        "wallet-rewards-stress-999",
      ]

      const summaries = sampledWallets.map((wallet) => {
        const progress = evaluateAllTasksForUser({ tasks, wallet, events, claims: [], now })
        const summary = calculateRewardSummary({ tasks, wallet, events, claims: [], now })

        expect(progress).toHaveLength(tasks.length)
        expect(progress.every((item) => Number.isFinite(item.progress))).toBe(true)
        expect(progress.every((item) => Number.isFinite(item.target))).toBe(true)
        expect(summary.totalTaskCount).toBe(tasks.length)
        expect(Number.isFinite(summary.totalEarnedAmount)).toBe(true)
        expect(Number.isFinite(summary.totalClaimableAmount)).toBe(true)
        expect(Number.isFinite(summary.totalClaimedAmount)).toBe(true)

        return summary
      })

      expect(summaries[0]?.totalClaimableAmount).toBeGreaterThan(summaries[1]?.totalClaimableAmount ?? 0)
      expect(summaries[0]?.claimableTaskCount).toBeGreaterThan(10)
      expect(summaries[4]?.completedTaskCount).toBeGreaterThanOrEqual(2)
    },
  )
})
