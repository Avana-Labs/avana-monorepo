import { describe, expect, it } from "vitest"
import { evaluateTaskProgress } from "@/app/lib/rewards-engine"
import type { RewardTask } from "@/app/lib/rewards-engine"
import { SandboxRewardsActionAdapter, buildDefaultRewardsSessionState } from "@/app/lib/rewards-system"

const now = Date.UTC(2026, 5, 19)
const wallet = "wallet-new-user"

describe("new user reward tasks", () => {
  it("completes onboarding quests through real sandbox actions", async () => {
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
    await adapter.completeEducation(wallet)
    await adapter.favoriteMarket(wallet, "gho")
    await adapter.recordSimulation(wallet, "lend")

    const progress = await adapter.refreshTaskProgress(wallet)
    expect(progress.find((item) => item.taskId === "connect-wallet")?.status).toBe("claimable")
    expect(progress.find((item) => item.taskId === "review-risk-basics")?.status).toBe("claimable")
    expect(progress.find((item) => item.taskId === "favorite-market")?.status).toBe("claimable")
    expect(progress.find((item) => item.taskId === "run-first-simulation")?.status).toBe("claimable")
  })

  it("unlocks the sandbox cool-down timer", () => {
    // The curated catalog dropped its wait_since_login quests; keep engine coverage
    // of the cool-down timer requirement through an inline fixture.
    const task: RewardTask = {
      id: "synthetic-sandbox-cool-down",
      category: "new_user",
      tag: "activity",
      title: "Synthetic sandbox cool-down",
      description: "inline wait_since_login fixture",
      rewardAmount: 25,
      rewardSymbol: "AVA",
      actionLabel: "Waiting",
      actionKind: "wait_timer",
      requirement: { type: "wait_since_login", waitMs: 3 * 60_000 },
      repeatable: false,
    }

    const progress = evaluateTaskProgress({
      task,
      wallet,
      events: [],
      claims: [],
      now: now + 3 * 60_000,
      firstLoginAt: now,
    })

    expect(progress.status).toBe("claimable")
  })
})
