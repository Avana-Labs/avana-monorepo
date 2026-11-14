import type { RewardTask } from "./types"

const MINUTE_MS = 60 * 1000
const HOUR_MS = 60 * MINUTE_MS
const DAY_MS = 24 * HOUR_MS

/**
 * The active rewards catalog: 15 curated quests, three per product tab
 * (Getting started / Lend / Borrow / Multiply / Referrals). Every quest is
 * meant to teach a real surface of Avana while earning AVA — no idle wait
 * timers, no circular "claim to earn a claim" tasks, no duplicate tiers.
 *
 * The server-authoritative payout table in `convex/sandbox/rewards_catalog.ts`
 * is a superset (it still lists retired ids so historical claims resolve); this
 * file is the sole source of truth for which quests are actually offered.
 */
export function buildDefaultRewardsCatalog(now = Date.now()): RewardTask[] {
  return [
    // —— Getting started ——
    {
      id: "connect-wallet",
      category: "new_user",
      tag: "setup",
      title: "Boot your sandbox wallet",
      description: "Your Avana session is live — this quest unlocks automatically when you land.",
      rewardAmount: 25,
      rewardSymbol: "AVA",
      actionLabel: "Connected",
      actionKind: "auto",
      requirement: { type: "event_count", eventTypes: ["wallet_connected"], targetCount: 1 },
      repeatable: false,
    },
    {
      id: "review-risk-basics",
      category: "new_user",
      tag: "education",
      title: "Read the sandbox risk primer",
      description: "Open the 60-second LP risk briefing before you simulate any position.",
      rewardAmount: 15,
      rewardSymbol: "AVA",
      actionLabel: "Read primer",
      actionKind: "education_modal",
      requirement: { type: "education_completed", targetCount: 1 },
      repeatable: false,
    },
    {
      id: "run-first-simulation",
      category: "new_user",
      tag: "simulation",
      title: "Preview your first trade",
      description: "Run a real sandbox preview on Borrow, Lend, or Multiply — no funds move.",
      rewardAmount: 20,
      rewardSymbol: "AVA",
      actionLabel: "Preview",
      actionKind: "simulate_modal",
      requirement: { type: "event_count", eventTypes: ["simulation_created"], targetCount: 1 },
      repeatable: false,
    },

    // —— Lend ——
    {
      id: "first-lend-deposit",
      category: "new_user",
      tag: "lend",
      title: "Make your first sandbox lend",
      description: "Deposit into any Lend market. Your live session records the quest automatically.",
      rewardAmount: 40,
      rewardSymbol: "AVA",
      actionLabel: "Go to Lend",
      actionKind: "deep_link",
      requirement: { type: "event_count", eventTypes: ["lend_deposited"], targetCount: 1, product: "lend" },
      repeatable: false,
    },
    {
      id: "supply-5k-lend",
      category: "challenge",
      tag: "volume",
      title: "Lend $500 in the sandbox",
      description: "Stack sandbox lend deposits until you reach $500 supplied.",
      rewardAmount: 100,
      rewardSymbol: "AVA",
      actionLabel: "Lend more",
      actionKind: "deep_link",
      requirement: { type: "aggregate_volume", eventTypes: ["lend_deposited"], targetUsd: 500 },
      expiresAt: now + 30 * DAY_MS,
      repeatable: false,
    },
    {
      id: "favorite-market",
      category: "new_user",
      tag: "lend",
      title: "Pin a Lend market to watch",
      description: "Pick a Lend market to track in your sandbox watchlist.",
      rewardAmount: 10,
      rewardSymbol: "AVA",
      actionLabel: "Pin market",
      actionKind: "favorite_modal",
      requirement: { type: "event_count", eventTypes: ["market_favorited"], targetCount: 1 },
      repeatable: false,
    },

    // —— Borrow ——
    {
      id: "first-borrow",
      category: "new_user",
      tag: "borrow",
      title: "Open your first sandbox borrow",
      description: "Borrow against LP collateral on the Borrow page — the quest completes on success.",
      rewardAmount: 50,
      rewardSymbol: "AVA",
      actionLabel: "Go to Borrow",
      actionKind: "deep_link",
      requirement: { type: "event_count", eventTypes: ["borrow_opened"], targetCount: 1, product: "borrow" },
      repeatable: false,
    },
    {
      id: "first-repay",
      category: "new_user",
      tag: "borrow",
      title: "Repay a sandbox loan",
      description: "Repay any borrow position you opened — a healthy loop in the demo world.",
      rewardAmount: 25,
      rewardSymbol: "AVA",
      actionLabel: "Repay on Borrow",
      actionKind: "deep_link",
      requirement: { type: "event_count", eventTypes: ["borrow_repaid"], targetCount: 1, product: "borrow" },
      repeatable: false,
    },
    {
      id: "use-curve-position",
      category: "challenge",
      tag: "integration",
      title: "Curve sandbox tour",
      description: "Visit the Curve-style borrow market tour and mark it complete.",
      rewardAmount: 80,
      rewardSymbol: "AVA",
      actionLabel: "Start tour",
      actionKind: "sandbox_tour",
      requirement: {
        type: "event_count",
        eventTypes: ["sandbox_tour_completed"],
        targetCount: 1,
        marketId: "curve-sandbox-tour",
      },
      expiresAt: now + 30 * DAY_MS,
      repeatable: false,
    },

    // —— Multiply ——
    {
      id: "first-multiply",
      category: "new_user",
      tag: "multiply",
      title: "Open your first sandbox multiply",
      description: "Create a Multiply position in the sandbox and let the session bridge log it.",
      rewardAmount: 60,
      rewardSymbol: "AVA",
      actionLabel: "Go to Multiply",
      actionKind: "deep_link",
      requirement: { type: "event_count", eventTypes: ["multiply_opened"], targetCount: 1, product: "multiply" },
      repeatable: false,
    },
    {
      id: "first-deleverage",
      category: "new_user",
      tag: "multiply",
      title: "Deleverage a sandbox position",
      description: "Reduce any Multiply position to practice risk management.",
      rewardAmount: 35,
      rewardSymbol: "AVA",
      actionLabel: "Deleverage",
      actionKind: "deep_link",
      requirement: { type: "event_count", eventTypes: ["multiply_deleveraged"], targetCount: 1, product: "multiply" },
      repeatable: false,
    },
    {
      id: "use-uniswap-v4-position",
      category: "challenge",
      tag: "integration",
      title: "Uniswap v4 sandbox tour",
      description: "Walk through the Uniswap v4 sandbox market and check it off.",
      rewardAmount: 80,
      rewardSymbol: "AVA",
      actionLabel: "Start tour",
      actionKind: "sandbox_tour",
      requirement: {
        type: "event_count",
        eventTypes: ["sandbox_tour_completed"],
        targetCount: 1,
        marketId: "uniswap-v4-sandbox-tour",
      },
      expiresAt: now + 30 * DAY_MS,
      repeatable: false,
    },

    // —— Referrals ——
    {
      id: "share-referral-link",
      category: "referral",
      tag: "referral",
      title: "Copy your sandbox invite link",
      description: "Generate and copy a referral link you can share with friends.",
      rewardAmount: 15,
      rewardSymbol: "AVA",
      actionLabel: "Copy link",
      actionKind: "copy_referral",
      requirement: { type: "event_count", eventTypes: ["referral_link_created"], targetCount: 1, product: "referral" },
      repeatable: false,
    },
    {
      id: "invite-first-wallet",
      category: "referral",
      tag: "referral",
      title: "Send your first sandbox invite",
      description: "Simulate inviting a friend wallet into your Avana sandbox crew.",
      rewardAmount: 40,
      rewardSymbol: "AVA",
      actionLabel: "Send invite",
      actionKind: "sandbox_referral_invite",
      requirement: { type: "referral_count", eventTypes: ["referral_connected"], targetCount: 1 },
      repeatable: false,
    },
    {
      id: "bring-3-active-users",
      category: "referral",
      tag: "referral",
      title: "Activate 3 sandbox friends",
      description: "Three referred wallets complete a product action in your sandbox network.",
      rewardAmount: 140,
      rewardSymbol: "AVA",
      actionLabel: "Activate",
      actionKind: "sandbox_referral_activate",
      requirement: { type: "referral_count", eventTypes: ["referral_activated"], targetCount: 3 },
      repeatable: false,
    },
  ]
}

export const REWARD_TASK_DEEP_LINKS: Record<string, string> = {
  "first-lend-deposit": "/lend",
  "first-borrow": "/borrow",
  "first-multiply": "/multiply",
  "first-repay": "/borrow",
  "first-deleverage": "/multiply",
  "supply-5k-lend": "/lend",
}

export const REWARD_SANDBOX_TOURS: Record<string, { marketId: string; href: string; label: string }> = {
  "use-curve-position": { marketId: "curve-sandbox-tour", href: "/borrow", label: "Curve sandbox" },
  "use-uniswap-v4-position": { marketId: "uniswap-v4-sandbox-tour", href: "/borrow", label: "Uniswap v4 sandbox" },
}
