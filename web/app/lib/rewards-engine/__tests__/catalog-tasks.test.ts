import { describe, expect, it } from "vitest"
import {
  applyActivityEvent,
  buildDefaultRewardsCatalog,
  evaluateTaskProgress,
  type RewardsEngineState,
  type RewardTask,
} from "@/app/lib/rewards-engine"
import { SandboxRewardsActionAdapter, buildDefaultRewardsSessionState } from "@/app/lib/rewards-system"

const DAY_MS = 24 * 60 * 60 * 1000
const now = Date.UTC(2026, 5, 19)
const wallet = "wallet-catalog"

function evaluateTask(taskId: string, state: RewardsEngineState, firstLoginAt: number, evaluationNow: number) {
  const task = buildDefaultRewardsCatalog(now).find((entry) => entry.id === taskId)
  if (!task) throw new Error(`missing ${taskId}`)
  return evaluateTaskProgress({
    task,
    wallet,
    events: state.events,
    claims: state.claims,
    now: evaluationNow,
    firstLoginAt,
  })
}

describe("full rewards catalog", () => {
  const tasks = buildDefaultRewardsCatalog(now)

  it("covers every catalog task with an action kind", () => {
    expect(tasks).toHaveLength(15)
    expect(tasks.every((task) => task.actionKind)).toBe(true)
  })

  it("completes interactive sandbox flows through the action adapter", async () => {
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
    await adapter.recordSimulation(wallet, "borrow")
    await adapter.recordSandboxTour(wallet, "use-curve-position")
    await adapter.recordSandboxTour(wallet, "use-uniswap-v4-position")
    // Generic extra tours: the adapter records a fresh market-tour id for any taskId
    // that isn't the curve/uniswap quest, exercising that branch without a catalog quest.
    await adapter.recordSandboxTour(wallet, "extra-market-tour")
    await adapter.recordSandboxTour(wallet, "extra-market-tour")
    await adapter.recordSandboxTour(wallet, "extra-market-tour")
    await adapter.recordDailyCheckin(wallet)
    await adapter.recordReferralLinkCopied(wallet)
    await adapter.runReferralSandboxStep(wallet, "invite")
    await adapter.runReferralSandboxStep(wallet, "activate")
    await adapter.runReferralSandboxStep(wallet, "fund")

    expect(evaluateTask("review-risk-basics", state, now, now).status).toBe("claimable")
    expect(evaluateTask("favorite-market", state, now, now).status).toBe("claimable")
    expect(evaluateTask("run-first-simulation", state, now, now).status).toBe("claimable")
    expect(evaluateTask("use-curve-position", state, now, now).status).toBe("claimable")
    expect(evaluateTask("share-referral-link", state, now, now).status).toBe("claimable")
    expect(evaluateTask("invite-first-wallet", state, now, now).status).toBe("claimable")
  })

  it("unlocks wait timers after the sandbox cool-down", () => {
    // The curated catalog no longer ships a wait_since_login quest, but the engine
    // still supports that requirement type — cover it with an inline fixture.
    const task: RewardTask = {
      id: "synthetic-cool-down-timer",
      category: "challenge",
      tag: "activity",
      title: "Synthetic cool-down timer",
      description: "inline wait_since_login fixture",
      rewardAmount: 50,
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

  for (const task of tasks.filter((entry) => entry.requirement.type !== "wait_since_login")) {
    it(`defines a completable sandbox path for ${task.id}`, () => {
      const bootstrap = [
        {
          id: `${wallet}:connect`,
          wallet,
          product: "profile" as const,
          type: "wallet_connected" as const,
          timestamp: now,
        },
        {
          id: `${wallet}:profile`,
          wallet,
          product: "profile" as const,
          type: "profile_completed" as const,
          timestamp: now + 1,
        },
      ]
      const state = bootstrap.reduce((next, event) => applyActivityEvent(next, event), {
        events: [],
        claims: [],
      } as RewardsEngineState)
      const evaluationNow = task.expiresAt ? task.expiresAt - DAY_MS : now + 30 * DAY_MS
      const progress = evaluateTaskProgress({
        task,
        wallet,
        events: state.events,
        claims: state.claims,
        now: evaluationNow,
        firstLoginAt: now,
      })

      expect(["available", "in_progress", "claimable"]).toContain(progress.status)
    })
  }
})
