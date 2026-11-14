import { describe, expect, it } from "vitest"
import {
  applyActivityEvent,
  buildDefaultRewardsCatalog,
  calculateRewardSummary,
  claimReward,
  evaluateAllTasksForUser,
  getClaimableRewards,
} from "@/app/lib/rewards-engine"

describe("rewards engine evaluation", () => {
  it("progresses tasks, creates claims, and updates summary deterministically", () => {
    const now = Date.UTC(2026, 5, 19)
    const wallet = "wallet-demo"
    const tasks = buildDefaultRewardsCatalog(now)
    let state = { events: [], claims: [] as ReturnType<typeof claimReward>["claim"][] }

    state = applyActivityEvent(state, { id: "1", wallet, product: "profile", type: "wallet_connected", timestamp: now })
    state = applyActivityEvent(state, {
      id: "2",
      wallet,
      product: "profile",
      type: "profile_completed",
      timestamp: now + 1,
    })
    state = applyActivityEvent(state, {
      id: "3",
      wallet,
      product: "education",
      type: "education_completed",
      timestamp: now + 2,
    })
    state = applyActivityEvent(state, {
      id: "4",
      wallet,
      product: "lend",
      type: "lend_deposited",
      amountUsd: 6_000,
      timestamp: now + 3,
    })
    state = applyActivityEvent(state, {
      id: "5",
      wallet,
      product: "borrow",
      type: "borrow_opened",
      amountUsd: 2_500,
      timestamp: now + 4,
    })
    state = applyActivityEvent(state, {
      id: "6",
      wallet,
      product: "multiply",
      type: "multiply_opened",
      amountUsd: 3_000,
      timestamp: now + 5,
    })
    state = applyActivityEvent(state, {
      id: "7",
      wallet,
      product: "borrow",
      type: "borrow_repaid",
      amountUsd: 500,
      timestamp: now + 6,
    })
    state = applyActivityEvent(state, {
      id: "8",
      wallet,
      product: "multiply",
      type: "multiply_deleveraged",
      amountUsd: 1_000,
      timestamp: now + 7,
    })

    const progressBeforeClaim = evaluateAllTasksForUser({
      tasks,
      wallet,
      events: state.events,
      claims: state.claims,
      now,
    })
    expect(getClaimableRewards(progressBeforeClaim).length).toBeGreaterThan(5)

    const firstBorrow = progressBeforeClaim.find((item) => item.taskId === "first-borrow")
    expect(firstBorrow?.status).toBe("claimable")

    const borrowTask = tasks.find((task) => task.id === "first-borrow")
    if (!borrowTask || !firstBorrow) throw new Error("missing first-borrow fixtures")

    const { claim, event } = claimReward({ wallet, task: borrowTask, progress: firstBorrow, now: now + 100 })
    state = { claims: [...state.claims, claim], events: [...state.events, event] }

    const progressAfterClaim = evaluateAllTasksForUser({
      tasks,
      wallet,
      events: state.events,
      claims: state.claims,
      now: now + 101,
    })
    expect(progressAfterClaim.find((item) => item.taskId === "first-borrow")?.status).toBe("claimed")

    const summary = calculateRewardSummary({
      tasks,
      wallet,
      events: state.events,
      claims: state.claims,
      now: now + 101,
    })
    expect(summary.totalClaimedAmount).toBe(50)
    expect(summary.totalClaimableAmount).toBeGreaterThan(0)
    expect(summary.completedTaskCount).toBeGreaterThan(5)
  })
})
