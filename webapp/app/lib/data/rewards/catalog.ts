export type RewardsPromoTabId = "getting-started" | "lend" | "borrow" | "referrals"

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
  /** "coming_soon" until a rewards source exists: the card renders with its action disabled. */
  status?: string
  progressLabel?: string
}

export const REWARDS_PROMO_TABS = [
  { id: "lend", label: "Lend" },
  { id: "borrow", label: "Borrow" },
  { id: "referrals", label: "Referrals" },
] as const satisfies ReadonlyArray<{ id: RewardsPromoTabId; label: string }>

/**
 * Per-task illustration under public/asset-rewards; an unmapped id falls back to its tag icon.
 * Rendered via next/image, so the 1254² source ships downscaled as lazy WebP/AVIF.
 */
const REWARDS_IMAGE_BY_TASK_ID: Record<string, string> = {
  "connect-wallet": "/asset-rewards/2.png",
  "review-risk-basics": "/asset-rewards/1.png",
  "favorite-market": "/asset-rewards/11.png",
  "first-lend-deposit": "/asset-rewards/3.png",
  "supply-500-lend": "/asset-rewards/5.png",
  "favorite-lend-market": "/asset-rewards/13.png",
  "first-borrow": "/asset-rewards/6.png",
  "first-repay": "/asset-rewards/10.png",
  "pledge-uniswap-v3-position": "/asset-rewards/14.png",
  "share-referral-link": "/asset-rewards/12.png",
  "invite-first-wallet": "/asset-rewards/4.png",
  "bring-3-active-users": "/asset-rewards/8.png",
}

export function imageForTask(taskId: string): string | undefined {
  return REWARDS_IMAGE_BY_TASK_ID[taskId]
}

export function emptyRewardsQuestsByTab<T>(): Record<RewardsPromoTabId, T[]> {
  return {
    "getting-started": [],
    lend: [],
    borrow: [],
    referrals: [],
  }
}
