import type { RewardActivityEvent, RewardTask, RewardTaskCategory } from "./types"
import { buildDefaultRewardsCatalog } from "./catalog"

const DAY_MS = 24 * 60 * 60 * 1000

type CompletionContext = {
  wallet: string
  now: number
}

function event(
  context: CompletionContext,
  id: string,
  product: RewardActivityEvent["product"],
  type: RewardActivityEvent["type"],
  extra: Partial<RewardActivityEvent> = {},
): RewardActivityEvent {
  return {
    id: `${context.wallet}:${id}`,
    wallet: context.wallet,
    product,
    type,
    timestamp: context.now,
    ...extra,
  }
}

export function buildProfileBootstrapEvents(context: CompletionContext): RewardActivityEvent[] {
  return [
    event(context, "wallet_connected", "profile", "wallet_connected"),
    event(context, "profile_completed", "profile", "profile_completed", { timestamp: context.now + 1 }),
  ]
}

function buildNewUserCompletionEvents(taskId: string, context: CompletionContext): RewardActivityEvent[] {
  switch (taskId) {
    case "connect-wallet":
      return [event(context, "wallet_connected", "profile", "wallet_connected")]
    case "create-profile":
      return [event(context, "profile_completed", "profile", "profile_completed")]
    case "review-risk-basics":
      return [event(context, "education_completed", "education", "education_completed")]
    case "favorite-market":
      return [event(context, "market_favorited", "profile", "market_favorited", { marketId: "gho" })]
    case "run-first-simulation":
      return [event(context, "simulation_created", "borrow", "simulation_created")]
    case "first-lend-deposit":
      return [event(context, "lend_deposited", "lend", "lend_deposited", { amountUsd: 500, marketId: "gho" })]
    case "first-borrow":
      return [
        event(context, "borrow_opened", "borrow", "borrow_opened", {
          amountUsd: 1_000,
          marketId: "uni-v3-bluechip-weth-usdc",
        }),
      ]
    case "first-multiply":
      return [
        event(context, "multiply_opened", "multiply", "multiply_opened", { amountUsd: 1_000, marketId: "eth-usdt" }),
      ]
    case "first-repay":
      return [
        event(context, "borrow_repaid", "borrow", "borrow_repaid", {
          amountUsd: 250,
          marketId: "uni-v3-bluechip-weth-usdc",
        }),
      ]
    case "first-deleverage":
      return [
        event(context, "multiply_deleveraged", "multiply", "multiply_deleveraged", {
          amountUsd: 500,
          marketId: "eth-usdt",
        }),
      ]
    case "first-reward-claim":
      return [event(context, "reward_claimed", "rewards", "reward_claimed", { amountUsd: 25 })]
    case "maintain-safe-account":
      return []
    default:
      return []
  }
}

function buildChallengeCompletionEvents(taskId: string, context: CompletionContext): RewardActivityEvent[] {
  const { now } = context

  switch (taskId) {
    case "supply-5k-lend":
      return [event(context, "lend_500", "lend", "lend_deposited", { amountUsd: 500, marketId: "gho" })]
    case "borrow-2k":
      return [event(context, "borrow_200", "borrow", "borrow_opened", { amountUsd: 200, marketId: "borrow-1" })]
    case "open-2x-multiply":
      return [
        event(context, "multiply_2x", "multiply", "multiply_opened", { amountUsd: 2_500, marketId: "multiply-1" }),
      ]
    case "use-3-products":
      return [
        event(context, "lend_product", "lend", "lend_deposited", { amountUsd: 100, marketId: "gho", timestamp: now }),
        event(context, "borrow_product", "borrow", "borrow_opened", {
          amountUsd: 100,
          marketId: "borrow-1",
          timestamp: now + 1,
        }),
        event(context, "multiply_product", "multiply", "multiply_opened", {
          amountUsd: 100,
          marketId: "multiply-1",
          timestamp: now + 2,
        }),
      ]
    case "use-curve-position":
      return [event(context, "curve_tour", "borrow", "sandbox_tour_completed", { marketId: "curve-sandbox-tour" })]
    case "use-uniswap-v4-position":
      return [
        event(context, "uni_v4_tour", "borrow", "sandbox_tour_completed", { marketId: "uniswap-v4-sandbox-tour" }),
      ]
    case "maintain-hf-above-2":
      return []
    case "keep-multiply-safe":
      return []
    case "complete-5-borrow-repay-cycles":
      return Array.from({ length: 3 }, (_, index) =>
        event(context, `repay_cycle_${index}`, "borrow", "borrow_repaid", {
          amountUsd: 100,
          marketId: `borrow-${index}`,
          timestamp: now + index,
        }),
      )
    case "complete-3-multiply-deleverage-cycles":
      return Array.from({ length: 2 }, (_, index) =>
        event(context, `deleverage_cycle_${index}`, "multiply", "multiply_deleveraged", {
          amountUsd: 100,
          marketId: `multiply-${index}`,
          timestamp: now + index,
        }),
      )
    case "activate-5-markets":
      return Array.from({ length: 3 }, (_, index) =>
        event(context, `market_tour_${index}`, "borrow", "sandbox_tour_completed", {
          marketId: `market-tour-${index + 1}`,
          timestamp: now + index,
        }),
      )
    case "claim-rewards-5-times":
      return Array.from({ length: 3 }, (_, index) =>
        event(context, `reward_claim_${index}`, "rewards", "reward_claimed", {
          amountUsd: 10,
          timestamp: now + index,
        }),
      )
    case "4-week-activity-streak":
      return Array.from({ length: 3 }, (_, day) =>
        event(context, `daily_${day}`, "profile", "daily_checkin", {
          timestamp: now + day * DAY_MS,
        }),
      )
    case "grow-portfolio-10k":
      return [
        event(context, "grow_lend", "lend", "lend_deposited", { amountUsd: 400, marketId: "gho", timestamp: now }),
        event(context, "grow_borrow", "borrow", "borrow_opened", {
          amountUsd: 300,
          marketId: "borrow-1",
          timestamp: now + 1,
        }),
        event(context, "grow_multiply", "multiply", "multiply_opened", {
          amountUsd: 350,
          marketId: "multiply-1",
          timestamp: now + 2,
        }),
      ]
    case "open-8-active-positions":
      return Array.from({ length: 3 }, (_, index) => {
        const kinds = ["lend_deposited", "borrow_opened", "multiply_opened"] as const
        const products = ["lend", "borrow", "multiply"] as const
        const kindIndex = index % 3
        return event(context, `position_${index}`, products[kindIndex]!, kinds[kindIndex]!, {
          amountUsd: 100,
          marketId: `position-${index}`,
          timestamp: now + index,
        })
      })
    default:
      return []
  }
}

function buildReferralCompletionEvents(taskId: string, context: CompletionContext): RewardActivityEvent[] {
  const { wallet, now } = context

  switch (taskId) {
    case "share-referral-link":
      return [event(context, "referral_link_created", "referral", "referral_link_created")]
    case "invite-first-wallet":
      return [
        event(context, "referral_link_created", "referral", "referral_link_created", { timestamp: now }),
        event(context, "referral_connected_0", "referral", "referral_connected", {
          referredWallet: `${wallet}-ref-0`,
          timestamp: now + 1,
        }),
      ]
    case "first-funded-referral":
      return [
        event(context, "referral_funded_0", "referral", "referral_funded", {
          referredWallet: `${wallet}-ref-0`,
          amountUsd: 1_000,
        }),
      ]
    case "bring-3-active-users":
      return Array.from({ length: 3 }, (_, index) =>
        event(context, `referral_activated_${index}`, "referral", "referral_activated", {
          referredWallet: `${wallet}-active-${index}`,
          timestamp: now + index,
        }),
      )
    case "bring-5-active-users":
      return Array.from({ length: 5 }, (_, index) =>
        event(context, `referral_activated_5_${index}`, "referral", "referral_activated", {
          referredWallet: `${wallet}-active5-${index}`,
          timestamp: now + index,
        }),
      )
    case "referral-cohort-25k":
      return [
        event(context, "referral_funded_a", "referral", "referral_funded", {
          referredWallet: `${wallet}-cohort-a`,
          amountUsd: 250,
          timestamp: now,
        }),
        event(context, "referral_funded_b", "referral", "referral_funded", {
          referredWallet: `${wallet}-cohort-b`,
          amountUsd: 250,
          timestamp: now + 1,
        }),
      ]
    case "referral-streak":
      return Array.from({ length: 2 }, (_, index) =>
        event(context, `referral_streak_${index}`, "referral", "referral_activated", {
          referredWallet: `${wallet}-streak-${index}`,
          timestamp: now + index,
        }),
      )
    case "avana-ambassador":
      return Array.from({ length: 5 }, (_, index) =>
        event(context, `referral_ambassador_${index}`, "referral", "referral_activated", {
          referredWallet: `${wallet}-ambassador-${index}`,
          timestamp: now + index,
        }),
      )
    default:
      return []
  }
}

export function buildSandboxCompletionEvents(taskId: string, wallet: string, now = Date.now()): RewardActivityEvent[] {
  const context: CompletionContext = { wallet, now }
  const task = buildDefaultRewardsCatalog(now).find((entry) => entry.id === taskId)
  if (!task) return []

  switch (task.category) {
    case "new_user":
      return buildNewUserCompletionEvents(taskId, context)
    case "challenge":
      return buildChallengeCompletionEvents(taskId, context)
    case "referral":
      return buildReferralCompletionEvents(taskId, context)
  }
}

export function listTasksByCategory(category: RewardTaskCategory, now = Date.now()): RewardTask[] {
  return buildDefaultRewardsCatalog(now).filter((task) => task.category === category)
}
