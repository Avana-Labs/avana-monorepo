import { describe, expect, it } from "vitest"
import { buildDefaultRewardsCatalog, calculateRewardSummary, evaluateTaskProgress } from "@/app/lib/rewards-engine"
import type { RewardActivityEvent, RewardTask, RewardTaskRequirement } from "@/app/lib/rewards-engine"
import { buildSandboxCompletionEvents } from "@/app/lib/rewards-engine/task-completion"

const DAY_MS = 24 * 60 * 60 * 1000
const now = Date.UTC(2026, 5, 20)
const wallet = "wallet-task-requirements"

function getTask(taskId: string) {
  const task = buildDefaultRewardsCatalog(now).find((entry) => entry.id === taskId)
  if (!task) throw new Error(`missing task ${taskId}`)
  return task
}

function event(
  id: string,
  type: RewardActivityEvent["type"],
  product: RewardActivityEvent["product"],
  extra: Partial<RewardActivityEvent> = {},
): RewardActivityEvent {
  return {
    id,
    wallet,
    type,
    product,
    timestamp: now,
    ...extra,
  }
}

type TaskSpec = {
  taskId: string
  // Requirement types the curated catalog no longer uses (wait_since_login, streak,
  // holding_period, profile_completed) are still supported by the engine. Cover them
  // with an inline synthetic task fixture instead of a catalog lookup.
  task?: RewardTask
  partialEvents?: RewardActivityEvent[]
  completeEvents?: RewardActivityEvent[]
  beforeStatus?: "available" | "in_progress"
}

function syntheticTask(id: string, requirement: RewardTaskRequirement): RewardTask {
  return {
    id,
    category: "challenge",
    tag: "activity",
    title: `Synthetic ${id}`,
    description: `inline ${requirement.type} coverage fixture`,
    rewardAmount: 50,
    rewardSymbol: "AVA",
    actionLabel: "Go",
    actionKind: "product_action",
    requirement,
    repeatable: false,
  }
}

const taskSpecs: TaskSpec[] = [
  // —— Live catalog tasks (one per kept catalog quest) ——
  {
    taskId: "connect-wallet",
    completeEvents: [event("connect-wallet", "wallet_connected", "profile")],
  },
  {
    taskId: "review-risk-basics",
    completeEvents: [event("risk-primer", "education_completed", "education")],
  },
  {
    taskId: "favorite-market",
    completeEvents: [event("favorite-market", "market_favorited", "profile", { marketId: "gho" })],
  },
  {
    taskId: "run-first-simulation",
    completeEvents: [event("simulation", "simulation_created", "borrow")],
  },
  {
    taskId: "first-lend-deposit",
    completeEvents: [event("lend-first", "lend_deposited", "lend", { amountUsd: 100, marketId: "gho" })],
  },
  {
    taskId: "first-borrow",
    completeEvents: [event("borrow-first", "borrow_opened", "borrow", { amountUsd: 100, marketId: "pool-a" })],
  },
  {
    taskId: "first-multiply",
    completeEvents: [event("multiply-first", "multiply_opened", "multiply", { amountUsd: 100, marketId: "eth-usdt" })],
  },
  {
    taskId: "first-repay",
    completeEvents: [event("repay-first", "borrow_repaid", "borrow", { amountUsd: 50, marketId: "pool-a" })],
  },
  {
    taskId: "first-deleverage",
    completeEvents: [
      event("deleverage-first", "multiply_deleveraged", "multiply", { amountUsd: 50, marketId: "eth-usdt" }),
    ],
  },
  {
    taskId: "supply-5k-lend",
    partialEvents: [event("lend-200", "lend_deposited", "lend", { amountUsd: 200, marketId: "gho" })],
    completeEvents: [
      event("lend-200", "lend_deposited", "lend", { amountUsd: 200, marketId: "gho" }),
      event("lend-300", "lend_deposited", "lend", { amountUsd: 300, marketId: "gho", timestamp: now + 1 }),
    ],
    beforeStatus: "in_progress",
  },
  {
    taskId: "use-curve-position",
    completeEvents: [event("curve-tour", "sandbox_tour_completed", "borrow", { marketId: "curve-sandbox-tour" })],
  },
  {
    taskId: "use-uniswap-v4-position",
    completeEvents: [
      event("uniswap-tour", "sandbox_tour_completed", "borrow", { marketId: "uniswap-v4-sandbox-tour" }),
    ],
  },
  {
    taskId: "share-referral-link",
    completeEvents: [event("ref-link", "referral_link_created", "referral")],
  },
  {
    taskId: "invite-first-wallet",
    completeEvents: [event("ref-connect", "referral_connected", "referral", { referredWallet: "friend-1" })],
  },
  {
    taskId: "bring-3-active-users",
    partialEvents: [
      event("ref-active-1", "referral_activated", "referral", { referredWallet: "friend-1" }),
      event("ref-active-2", "referral_activated", "referral", { referredWallet: "friend-2", timestamp: now + 1 }),
    ],
    completeEvents: [
      event("ref-active-1", "referral_activated", "referral", { referredWallet: "friend-1" }),
      event("ref-active-2", "referral_activated", "referral", { referredWallet: "friend-2", timestamp: now + 1 }),
      event("ref-active-3", "referral_activated", "referral", { referredWallet: "friend-3", timestamp: now + 2 }),
    ],
    beforeStatus: "in_progress",
  },

  // —— Synthetic fixtures for requirement types the catalog no longer uses ——
  // The engine still supports these; keep engine-level coverage even though no
  // curated quest exercises them anymore.
  {
    taskId: "synthetic-wait-since-login",
    task: syntheticTask("synthetic-wait-since-login", { type: "wait_since_login", waitMs: 3 * DAY_MS }),
  },
  {
    taskId: "synthetic-streak",
    task: syntheticTask("synthetic-streak", {
      type: "streak",
      eventTypes: ["daily_checkin"],
      targetCount: 3,
      interval: "day",
    }),
    partialEvents: [
      event("streak-1", "daily_checkin", "profile", { timestamp: now }),
      event("streak-2", "daily_checkin", "profile", { timestamp: now + DAY_MS }),
    ],
    completeEvents: [
      event("streak-1", "daily_checkin", "profile", { timestamp: now }),
      event("streak-2", "daily_checkin", "profile", { timestamp: now + DAY_MS }),
      event("streak-3", "daily_checkin", "profile", { timestamp: now + 2 * DAY_MS }),
    ],
    beforeStatus: "in_progress",
  },
  {
    taskId: "synthetic-holding-period",
    task: syntheticTask("synthetic-holding-period", {
      type: "holding_period",
      eventTypes: ["lend_deposited"],
      targetCount: 1,
      durationDays: 7,
      minAmountUsd: 100,
    }),
    partialEvents: [
      event("hold-1", "lend_deposited", "lend", { amountUsd: 100, marketId: "gho", timestamp: now }),
      event("hold-2", "lend_deposited", "lend", { amountUsd: 100, marketId: "gho", timestamp: now + 3 * DAY_MS }),
    ],
    completeEvents: [
      event("hold-1", "lend_deposited", "lend", { amountUsd: 100, marketId: "gho", timestamp: now }),
      event("hold-2", "lend_deposited", "lend", { amountUsd: 100, marketId: "gho", timestamp: now + 7 * DAY_MS }),
    ],
    beforeStatus: "in_progress",
  },
  {
    taskId: "synthetic-profile-completed",
    task: syntheticTask("synthetic-profile-completed", { type: "profile_completed", targetCount: 1 }),
    completeEvents: [event("profile-complete", "profile_completed", "profile")],
  },
]

function evaluate(task: RewardTask, events: RewardActivityEvent[], evaluationNow: number, firstLoginAt = now) {
  return evaluateTaskProgress({
    task,
    wallet,
    events,
    claims: [],
    now: evaluationNow,
    firstLoginAt,
  })
}

describe("rewards task requirements", () => {
  it("covers every live rewards task and every engine requirement type", () => {
    expect(taskSpecs).toHaveLength(19)
    expect(new Set(taskSpecs.map((spec) => spec.taskId)).size).toBe(19)
  })

  for (const spec of taskSpecs) {
    it(`tracks ${spec.taskId} exactly at its described threshold`, () => {
      const task = spec.task ?? getTask(spec.taskId)

      if (task.requirement.type === "wait_since_login") {
        const beforeUnlock = evaluate(task, [], now + task.requirement.waitMs - 1)
        const atUnlock = evaluate(task, [], now + task.requirement.waitMs)

        expect(beforeUnlock.status).toBe(spec.beforeStatus ?? "in_progress")
        expect(atUnlock.status).toBe("claimable")
        expect(atUnlock.progress).toBe(1)
        expect(atUnlock.target).toBe(1)
        return
      }

      const partialEvents = spec.partialEvents ?? []
      const completeEvents = spec.completeEvents ?? buildSandboxCompletionEvents(task.id, wallet, now)

      if (partialEvents.length > 0) {
        const partial = evaluate(task, partialEvents, now + 5 * DAY_MS)
        expect(partial.status).toBe(spec.beforeStatus ?? "in_progress")
        expect(partial.progress).toBeLessThan(partial.target)
      } else {
        const empty = evaluate(task, [], now + 5 * DAY_MS)
        expect(empty.status).toBe("available")
      }

      const complete = evaluate(task, completeEvents, now + 5 * DAY_MS)
      expect(complete.status).toBe("claimable")
      expect(complete.progress).toBeGreaterThanOrEqual(complete.target)
    })
  }

  it("keeps reward totals and counts coherent after multi-quest claiming", () => {
    const tasks = buildDefaultRewardsCatalog(now)
    const events = [
      event("wallet", "wallet_connected", "profile"),
      event("profile", "profile_completed", "profile", { timestamp: now + 1 }),
      event("lend-200", "lend_deposited", "lend", { amountUsd: 200, marketId: "gho", timestamp: now + 2 }),
      event("lend-300", "lend_deposited", "lend", { amountUsd: 300, marketId: "gho", timestamp: now + 3 }),
      event("borrow-200", "borrow_opened", "borrow", { amountUsd: 200, marketId: "pool-a", timestamp: now + 4 }),
      event("claim-1", "reward_claimed", "rewards", { amountUsd: 25, timestamp: now + 5 }),
    ]
    const claims = [
      {
        claimId: "claim-connect",
        wallet,
        taskId: "connect-wallet",
        amount: 25,
        rewardSymbol: "AVA" as const,
        status: "confirmed" as const,
        syntheticTxHash: "tx-connect",
        claimedAt: now + 10,
      },
      {
        claimId: "claim-profile",
        wallet,
        taskId: "create-profile",
        amount: 20,
        rewardSymbol: "AVA" as const,
        status: "confirmed" as const,
        syntheticTxHash: "tx-profile",
        claimedAt: now + 11,
      },
    ]

    const summary = calculateRewardSummary({
      tasks,
      wallet,
      events,
      claims,
      now: now + 12,
      firstLoginAt: now,
    })

    // connect-wallet is claimed; a legacy create-profile claim still counts toward the
    // wallet's claimed total even though that quest was retired from the catalog.
    expect(summary.totalClaimedAmount).toBe(45)
    // Claimable now: first-lend-deposit (40) + supply-5k-lend (100) + first-borrow (50).
    expect(summary.totalClaimableAmount).toBe(190)
    // Earned = claimable (190) + connect-wallet's claimed 25.
    expect(summary.totalEarnedAmount).toBe(215)
    expect(summary.completedTaskCount).toBe(4)
    expect(summary.claimableTaskCount).toBe(3)
  })

  it("does not count repeated activity in the same market as multiple open-position milestones", () => {
    // No catalog quest uses distinctMarketIds after the curation; keep engine coverage
    // of the distinct-market de-duplication with an inline event_count fixture.
    const task = syntheticTask("synthetic-open-positions", {
      type: "event_count",
      eventTypes: ["lend_deposited", "borrow_opened", "multiply_opened"],
      targetCount: 3,
      distinctMarketIds: true,
    })
    const repeatedMarketEvents = [
      event("lend-repeat-1", "lend_deposited", "lend", { amountUsd: 100, marketId: "gho" }),
      event("lend-repeat-2", "lend_deposited", "lend", { amountUsd: 100, marketId: "gho", timestamp: now + 1 }),
      event("borrow-one", "borrow_opened", "borrow", { amountUsd: 100, marketId: "pool-a", timestamp: now + 2 }),
    ]
    const distinctMarketEvents = [
      event("lend-one", "lend_deposited", "lend", { amountUsd: 100, marketId: "gho" }),
      event("borrow-one", "borrow_opened", "borrow", { amountUsd: 100, marketId: "pool-a", timestamp: now + 1 }),
      event("multiply-one", "multiply_opened", "multiply", {
        amountUsd: 100,
        marketId: "eth-usdt",
        timestamp: now + 2,
      }),
    ]

    const repeated = evaluate(task, repeatedMarketEvents, now + DAY_MS)
    const distinct = evaluate(task, distinctMarketEvents, now + DAY_MS)

    expect(repeated.status).toBe("in_progress")
    expect(repeated.progress).toBe(2)
    expect(distinct.status).toBe("claimable")
    expect(distinct.progress).toBe(3)
  })
})
