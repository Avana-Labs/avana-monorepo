import { describe, expect, it } from "vitest"
import { buildDefaultRewardsCatalog, evaluateTaskProgress } from "@/app/lib/rewards-engine"
import type { RewardTask } from "@/app/lib/rewards-engine"
import { SandboxRewardsActionAdapter, buildDefaultRewardsSessionState } from "@/app/lib/rewards-system"

const now = Date.UTC(2026, 5, 19)
const wallet = "wallet-challenge"

describe("challenge reward tasks", () => {
  it("completes tour and check-in sandbox quests", async () => {
    let state = buildDefaultRewardsSessionState()
    state.firstLoginAt = now
    const adapter = new SandboxRewardsActionAdapter({
      readState: () => state,
      writeState: (next) => {
        state = typeof next === "function" ? next(state) : next
      },
      now: () => now,
    })

    await adapter.initializeRewardsForWallet(wallet)
    await adapter.recordSandboxTour(wallet, "use-curve-position")
    // Daily check-in is still a valid sandbox action even though the curated
    // catalog no longer ships a streak quest keyed to it.
    await adapter.recordDailyCheckin(wallet)

    const progress = await adapter.refreshTaskProgress(wallet)
    expect(progress.find((item) => item.taskId === "use-curve-position")?.status).toBe("claimable")
  })

  it("unlocks patience timers with honest wait requirements", () => {
    // No catalog quest uses wait_since_login after the curation; exercise the
    // engine's still-supported patience-timer requirement with an inline fixture.
    const task: RewardTask = {
      id: "synthetic-patience-timer",
      category: "challenge",
      tag: "activity",
      title: "Synthetic patience timer",
      description: "inline wait_since_login fixture",
      rewardAmount: 50,
      rewardSymbol: "AVA",
      actionLabel: "Waiting",
      actionKind: "wait_timer",
      requirement: { type: "wait_since_login", waitMs: 5 * 60_000 },
      repeatable: false,
    }

    const progress = evaluateTaskProgress({
      task,
      wallet,
      events: [],
      claims: [],
      now: now + 6 * 60_000,
      firstLoginAt: now,
    })

    expect(progress.status).toBe("claimable")
  })

  it("defines three challenge quests", () => {
    expect(buildDefaultRewardsCatalog(now).filter((task) => task.category === "challenge")).toHaveLength(3)
  })
})
