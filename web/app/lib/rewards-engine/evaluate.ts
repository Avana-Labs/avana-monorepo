import type {
  RewardActivityEvent,
  RewardClaim,
  RewardsEngineState,
  RewardsSummary,
  RewardTask,
  RewardTaskRequirement,
  RewardTaskStatus,
  UserRewardProgress,
} from "./types"
import { rewardsClaimTxHash } from "./claim-tx-hash"

function uniqueDays(timestamps: number[], interval: "day" | "week") {
  const size = interval === "day" ? 24 * 60 * 60 * 1000 : 7 * 24 * 60 * 60 * 1000
  return [...new Set(timestamps.map((timestamp) => Math.floor(timestamp / size)))]
}

function getRequirementTarget(requirement: RewardTaskRequirement) {
  switch (requirement.type) {
    case "aggregate_volume":
      return requirement.targetUsd
    case "education_completed":
    case "profile_completed":
    case "wait_since_login":
      return 1
    case "event_count":
    case "holding_period":
    case "referral_count":
    case "streak":
      return requirement.targetCount
  }
}

function countMatchingEvents(task: RewardTask, events: RewardActivityEvent[]) {
  const requirement = task.requirement
  if (requirement.type !== "event_count") return 0

  const matches = events.filter((event) => {
    if (!requirement.eventTypes.includes(event.type)) return false
    if (requirement.product && event.product !== requirement.product) return false
    if (requirement.marketId && event.marketId !== requirement.marketId) return false
    if (requirement.minAmountUsd != null && (event.amountUsd ?? 0) < requirement.minAmountUsd) return false
    return true
  })

  if (requirement.distinctProducts) {
    const products = new Set(
      matches.map((event) => event.product).filter((product) => requirement.distinctProducts?.includes(product)),
    )
    return products.size
  }

  if (requirement.distinctMarketIds) {
    return new Set(matches.map((event) => event.marketId).filter((marketId): marketId is string => Boolean(marketId)))
      .size
  }

  return matches.length
}

export function evaluateReferralProgress(task: RewardTask, events: RewardActivityEvent[]) {
  const requirement = task.requirement
  if (requirement.type !== "referral_count") return 0
  return new Set(
    events
      .filter((event) => requirement.eventTypes.includes(event.type))
      .map((event) => event.referredWallet)
      .filter(Boolean),
  ).size
}

export function evaluateStreakProgress(task: RewardTask, events: RewardActivityEvent[]) {
  const requirement = task.requirement
  if (requirement.type !== "streak") return 0
  const buckets = uniqueDays(
    events.filter((event) => requirement.eventTypes.includes(event.type)).map((event) => event.timestamp),
    requirement.interval,
  )

  if (buckets.length === 0) return 0

  let longest = 1
  let current = 1
  for (let index = 1; index < buckets.length; index += 1) {
    if (buckets[index] === buckets[index - 1] + 1) {
      current += 1
      longest = Math.max(longest, current)
    } else {
      current = 1
    }
  }
  return longest
}

export function evaluateVolumeProgress(task: RewardTask, events: RewardActivityEvent[]) {
  const requirement = task.requirement
  if (requirement.type !== "aggregate_volume") return 0
  return events
    .filter((event) => requirement.eventTypes.includes(event.type))
    .reduce((total, event) => total + Math.max(0, event.amountUsd ?? 0), 0)
}

export function evaluateHoldingPeriodProgress(task: RewardTask, events: RewardActivityEvent[]) {
  const requirement = task.requirement
  if (requirement.type !== "holding_period") return 0
  const matches = events
    .filter((event) => requirement.eventTypes.includes(event.type))
    .filter((event) => requirement.minAmountUsd == null || (event.amountUsd ?? 0) >= requirement.minAmountUsd)
    .sort((left, right) => left.timestamp - right.timestamp)

  if (matches.length === 0) return 0
  const elapsedMs = matches[matches.length - 1]!.timestamp - matches[0]!.timestamp
  const elapsedDays = elapsedMs / (24 * 60 * 60 * 1000)
  return elapsedDays >= requirement.durationDays
    ? requirement.targetCount
    : Math.max(0, Math.min(requirement.targetCount, elapsedDays / requirement.durationDays))
}

function evaluateWaitSinceLoginProgress(firstLoginAt: number | undefined, waitMs: number, now: number) {
  if (!firstLoginAt || firstLoginAt <= 0) return 0
  const elapsed = Math.max(0, now - firstLoginAt)
  return Math.min(1, elapsed / waitMs)
}

function evaluateRawProgress(
  task: RewardTask,
  events: RewardActivityEvent[],
  firstLoginAt: number | undefined,
  now: number,
) {
  switch (task.requirement.type) {
    case "event_count":
      return countMatchingEvents(task, events)
    case "aggregate_volume":
      return evaluateVolumeProgress(task, events)
    case "holding_period":
      return evaluateHoldingPeriodProgress(task, events)
    case "streak":
      return evaluateStreakProgress(task, events)
    case "referral_count":
      return evaluateReferralProgress(task, events)
    case "education_completed":
      return events.filter((event) => event.type === "education_completed").length
    case "profile_completed":
      return events.filter((event) => event.type === "profile_completed").length
    case "wait_since_login":
      return evaluateWaitSinceLoginProgress(firstLoginAt, task.requirement.waitMs, now)
  }
}

export function getTaskStatus(task: RewardTask, progress: UserRewardProgress, now: number): RewardTaskStatus {
  if (task.expiresAt != null && now > task.expiresAt && progress.claimedAmount === 0) {
    return "expired"
  }
  if (progress.claimedAmount > 0) return "claimed"
  if (progress.progress >= progress.target) return "claimable"
  if (progress.progress > 0) return "in_progress"
  return "available"
}

export function evaluateTaskProgress({
  task,
  wallet,
  events,
  claims,
  now,
  firstLoginAt,
}: {
  task: RewardTask
  wallet: string
  events: RewardActivityEvent[]
  claims: RewardClaim[]
  now: number
  firstLoginAt?: number
}): UserRewardProgress {
  const walletEvents = events.filter((event) => event.wallet === wallet)
  const walletClaims = claims.filter((claim) => claim.wallet === wallet && claim.taskId === task.id)
  const rawProgress = evaluateRawProgress(task, walletEvents, firstLoginAt, now)
  const target = getRequirementTarget(task.requirement)
  const cappedProgress =
    task.requirement.type === "aggregate_volume" || task.requirement.type === "wait_since_login"
      ? rawProgress
      : Math.min(rawProgress, target)
  const claimedAmount = walletClaims.reduce((total, claim) => total + claim.amount, 0)
  const completedAt = walletEvents
    .filter((event) => {
      if ("eventTypes" in task.requirement) return task.requirement.eventTypes.includes(event.type)
      if (task.requirement.type === "education_completed") return event.type === "education_completed"
      if (task.requirement.type === "profile_completed") return event.type === "profile_completed"
      return false
    })
    .at(-1)?.timestamp

  const progress: UserRewardProgress = {
    wallet,
    taskId: task.id,
    status: "available",
    progress: cappedProgress,
    target,
    claimableAmount: cappedProgress >= target && claimedAmount === 0 ? task.rewardAmount : 0,
    claimedAmount,
    startedAt: walletEvents[0]?.timestamp,
    completedAt: cappedProgress >= target ? completedAt : undefined,
    claimedAt: walletClaims.at(-1)?.claimedAt,
  }

  return {
    ...progress,
    status: getTaskStatus(task, progress, now),
  }
}

export function evaluateAllTasksForUser({
  tasks,
  wallet,
  events,
  claims,
  now,
  firstLoginAt,
}: {
  tasks: RewardTask[]
  wallet: string
  events: RewardActivityEvent[]
  claims: RewardClaim[]
  now: number
  firstLoginAt?: number
}) {
  return tasks.map((task) => evaluateTaskProgress({ task, wallet, events, claims, now, firstLoginAt }))
}

export function getClaimableRewards(progress: UserRewardProgress[]) {
  return progress.filter((item) => item.status === "claimable")
}

export function calculateRewardSummary({
  tasks,
  wallet,
  events,
  claims,
  now,
  firstLoginAt,
}: {
  tasks: RewardTask[]
  wallet: string
  events: RewardActivityEvent[]
  claims: RewardClaim[]
  now: number
  firstLoginAt?: number
}): RewardsSummary {
  const progress = evaluateAllTasksForUser({ tasks, wallet, events, claims, now, firstLoginAt })
  return {
    wallet,
    completedTaskCount: progress.filter((item) => item.status === "claimable" || item.status === "claimed").length,
    claimableTaskCount: progress.filter((item) => item.status === "claimable").length,
    totalTaskCount: tasks.length,
    totalEarnedAmount: progress.reduce((total, item) => total + item.claimableAmount + item.claimedAmount, 0),
    totalClaimableAmount: progress.reduce((total, item) => total + item.claimableAmount, 0),
    totalClaimedAmount: claims
      .filter((claim) => claim.wallet === wallet)
      .reduce((total, claim) => total + claim.amount, 0),
  }
}

export function applyActivityEvent(state: RewardsEngineState, event: RewardActivityEvent): RewardsEngineState {
  if (state.events.some((entry) => entry.id === event.id)) {
    return state
  }
  // Insert in timestamp order without re-sorting the whole array on every append. Events arrive
  // roughly monotonically, so scanning from the end finds the slot in O(1) for the common case
  // (the old `[...events, event].sort()` was O(n log n) on each of potentially thousands of
  // events per session).
  const events = state.events.slice()
  let index = events.length
  while (index > 0 && events[index - 1].timestamp > event.timestamp) index -= 1
  events.splice(index, 0, event)
  return { ...state, events }
}

export function claimReward({
  wallet,
  task,
  progress,
  now,
}: {
  wallet: string
  task: RewardTask
  progress: UserRewardProgress
  now: number
}) {
  if (progress.status !== "claimable") {
    throw new Error(`Task ${task.id} is not claimable for wallet ${wallet}`)
  }

  const claim: RewardClaim = {
    claimId: `${wallet}:${task.id}:${now}`,
    wallet,
    taskId: task.id,
    amount: task.rewardAmount,
    rewardSymbol: task.rewardSymbol,
    status: "confirmed",
    // Must match the durable Convex row's hash (useDurableRewardsClaim) so the
    // dashboard Activity feed dedups the two records into this quest-titled row.
    syntheticTxHash: rewardsClaimTxHash([task.id]),
    claimedAt: now,
  }

  const event: RewardActivityEvent = {
    id: `${claim.claimId}:event`,
    wallet,
    product: "rewards",
    type: "reward_claimed",
    amountUsd: task.rewardAmount,
    timestamp: now,
  }

  return { claim, event }
}
