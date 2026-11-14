export type RewardsPromoTabId = "getting-started" | "lend" | "borrow" | "multiply" | "referrals"

export type RewardsQuestIconId =
  | "droplets"
  | "flame"
  | "layers3"
  | "link2"
  | "lockKeyhole"
  | "orbit"
  | "repeat2"
  | "rocket"
  | "shieldCheck"
  | "sparkles"
  | "target"
  | "trophy"
  | "wallet"

export type RewardsQuest = {
  id: string
  title: string
  description: string
  reward: string
  cta: string
  category: string
  iconId: RewardsQuestIconId
  /** Per-task illustration under public/asset-rewards; when absent the card falls back to iconId. */
  image?: string
  expiration?: string
}

export const REWARDS_PROMO_TABS = [
  { id: "lend", label: "Lend" },
  { id: "borrow", label: "Borrow" },
  { id: "multiply", label: "Multiply" },
  { id: "referrals", label: "Referrals" },
] as const satisfies ReadonlyArray<{ id: RewardsPromoTabId; label: string }>

/**
 * Cross-cutting quests (volume, activity, risk, integration, streak) pinned by id to the
 * product they exercise; product-tagged quests route by tag, everything else falls to
 * "Getting started".
 */
const REWARDS_TAB_BY_TASK_ID: Record<string, RewardsPromoTabId> = {
  "supply-5k-lend": "lend",
  "use-curve-position": "borrow",
  "use-uniswap-v4-position": "multiply",
}

/**
 * Per-task illustration under public/asset-rewards; an unmapped id falls back to its tag icon.
 * Rendered via next/image, so the 1254² source ships downscaled as lazy WebP/AVIF.
 */
const REWARDS_IMAGE_BY_TASK_ID: Record<string, string> = {
  "connect-wallet": "/asset-rewards/2.png",
  "review-risk-basics": "/asset-rewards/1.png",
  "run-first-simulation": "/asset-rewards/13.png",
  "first-lend-deposit": "/asset-rewards/3.png",
  "supply-5k-lend": "/asset-rewards/5.png",
  "first-borrow": "/asset-rewards/6.png",
  "first-repay": "/asset-rewards/10.png",
  "first-multiply": "/asset-rewards/7.png",
  "first-deleverage": "/asset-rewards/15.png",
  "favorite-market": "/asset-rewards/11.png",
  "use-curve-position": "/asset-rewards/14.png",
  "use-uniswap-v4-position": "/asset-rewards/9.png",
  "share-referral-link": "/asset-rewards/12.png",
  "invite-first-wallet": "/asset-rewards/4.png",
  "bring-3-active-users": "/asset-rewards/8.png",
}

export function imageForTask(taskId: string): string | undefined {
  return REWARDS_IMAGE_BY_TASK_ID[taskId]
}

export function resolveRewardsPromoTab(task: { id: string; tag: string }): RewardsPromoTabId {
  const pinned = REWARDS_TAB_BY_TASK_ID[task.id]
  if (pinned) return pinned
  switch (task.tag) {
    case "lend":
      return "lend"
    case "borrow":
      return "borrow"
    case "multiply":
      return "multiply"
    case "referral":
      return "referrals"
    default:
      return "getting-started"
  }
}

export function emptyRewardsQuestsByTab<T>(): Record<RewardsPromoTabId, T[]> {
  return {
    "getting-started": [],
    lend: [],
    borrow: [],
    multiply: [],
    referrals: [],
  }
}
