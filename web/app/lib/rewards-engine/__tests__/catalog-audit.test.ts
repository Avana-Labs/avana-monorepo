import { describe, expect, it } from "vitest"
import { buildDefaultRewardsCatalog, evaluateTaskProgress } from "@/app/lib/rewards-engine"
import { buildSandboxCompletionEvents } from "@/app/lib/rewards-engine/task-completion"
import { getTaskDeepLink } from "@/app/lib/rewards-engine/task-actions"

const DAY_MS = 24 * 60 * 60 * 1000
const now = Date.UTC(2026, 5, 20)
const wallet = "wallet-rewards-audit"

function getTask(taskId: string) {
  const task = buildDefaultRewardsCatalog(now).find((entry) => entry.id === taskId)
  if (!task) throw new Error(`missing task ${taskId}`)
  return task
}

describe("rewards catalog audit", () => {
  it("keeps the catalog split at 9 new-user, 3 challenge, and 3 referral tasks", () => {
    const tasks = buildDefaultRewardsCatalog(now)

    expect(tasks.filter((task) => task.category === "new_user")).toHaveLength(9)
    expect(tasks.filter((task) => task.category === "challenge")).toHaveLength(3)
    expect(tasks.filter((task) => task.category === "referral")).toHaveLength(3)
  })

  it("builds expirations relative to the evaluation time instead of a fixed calendar anchor", () => {
    const baseline = Date.UTC(2026, 5, 20)
    const shifted = Date.UTC(2026, 7, 1)

    const baselineTask = buildDefaultRewardsCatalog(baseline).find((task) => task.id === "supply-5k-lend")
    const shiftedTask = buildDefaultRewardsCatalog(shifted).find((task) => task.id === "supply-5k-lend")

    expect(baselineTask?.expiresAt).toBe(baseline + 30 * DAY_MS)
    expect(shiftedTask?.expiresAt).toBe(shifted + 30 * DAY_MS)
  })

  it("tracks cumulative lend volume for the $500 sandbox lending quest", () => {
    const task = getTask("supply-5k-lend")
    const events = [
      {
        id: "lend-1",
        wallet,
        product: "lend" as const,
        type: "lend_deposited" as const,
        amountUsd: 200,
        timestamp: now,
      },
      {
        id: "lend-2",
        wallet,
        product: "lend" as const,
        type: "lend_deposited" as const,
        amountUsd: 300,
        timestamp: now + 1,
      },
    ]

    const progress = evaluateTaskProgress({
      task,
      wallet,
      events,
      claims: [],
      now: now + 2,
      firstLoginAt: now,
    })

    expect(progress.progress).toBe(500)
    expect(progress.target).toBe(500)
    expect(progress.status).toBe("claimable")
  })

  it("requires three activated referrals for the active-crew milestone", () => {
    const task = getTask("bring-3-active-users")
    const events = buildSandboxCompletionEvents(task.id, wallet, now)

    const progress = evaluateTaskProgress({
      task,
      wallet,
      events,
      claims: [],
      now: now + 10,
      firstLoginAt: now,
    })

    expect(task.title).toContain("3")
    expect(progress.progress).toBe(3)
    expect(progress.target).toBe(3)
    expect(progress.status).toBe("claimable")
  })

  it("provides deterministic routes for tracked product quests with clickable CTAs", () => {
    expect(getTaskDeepLink("first-lend-deposit")).toBe("/lend")
    expect(getTaskDeepLink("supply-5k-lend")).toBe("/lend")
    expect(getTaskDeepLink("first-borrow")).toBe("/borrow")
    expect(getTaskDeepLink("first-multiply")).toBe("/multiply")
  })

  it("completes every non-timer task through its sandbox audit fixture", () => {
    const tasks = buildDefaultRewardsCatalog(now)

    for (const task of tasks.filter((entry) => entry.requirement.type !== "wait_since_login")) {
      const events = buildSandboxCompletionEvents(task.id, wallet, now)
      const evaluationNow = task.expiresAt ? task.expiresAt - 1 : now + 10 * DAY_MS
      const progress = evaluateTaskProgress({
        task,
        wallet,
        events,
        claims: [],
        now: evaluationNow,
        firstLoginAt: now,
      })

      expect(events.length, task.id).toBeGreaterThan(0)
      expect(progress.status, task.id).toBe("claimable")
    }
  })

  it("unlocks every timer quest exactly from login time", () => {
    const tasks = buildDefaultRewardsCatalog(now).filter((task) => task.requirement.type === "wait_since_login")

    for (const task of tasks) {
      const beforeUnlock = evaluateTaskProgress({
        task,
        wallet,
        events: [],
        claims: [],
        now: now + task.requirement.waitMs - 1,
        firstLoginAt: now,
      })
      const unlocked = evaluateTaskProgress({
        task,
        wallet,
        events: [],
        claims: [],
        now: now + task.requirement.waitMs + 1,
        firstLoginAt: now,
      })

      expect(beforeUnlock.status, task.id).not.toBe("claimable")
      expect(unlocked.status, task.id).toBe("claimable")
    }
  })
})
