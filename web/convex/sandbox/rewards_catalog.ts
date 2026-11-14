import { codedError } from "../codedError"
/**
 * Server-authoritative rewards catalog. Mirrors the id → reward-amount slice of
 * `app/lib/rewards-engine/catalog.ts`; the client owns the presentation catalog
 * (titles, descriptions, requirement logic) but the SERVER is the sole source of
 * truth for how many AVA a claimed task pays out. Any drift the client sends via
 * `recordRewardsClaim` is discarded — the mutation looks up each task here and
 * recomputes the amount, so a forged inflated `amountUsd` cannot be persisted.
 *
 * When adding a new quest to `app/lib/rewards-engine/catalog.ts`, add its id and
 * `rewardAmount` here in the same PR. The convex-test on `recordRewardsClaim`
 * verifies this table can't be bypassed, but it cannot warn about missing entries.
 *
 * The sandbox AVA "price" is $1 (1 AVA = $1 USD), matching the client's implicit
 * 1:1 convention in `calculateRewardSummary` where `totalClaimableAmount` (AVA)
 * is displayed and persisted as `claimUsd`.
 */

export const REWARDS_CATALOG_AVA: Record<string, number> = {
  "connect-wallet": 25,
  "create-profile": 20,
  "review-risk-basics": 15,
  "favorite-market": 10,
  "run-first-simulation": 20,
  "first-lend-deposit": 40,
  "first-borrow": 50,
  "first-multiply": 60,
  "first-repay": 25,
  "first-deleverage": 35,
  "first-reward-claim": 30,
  "maintain-safe-account": 50,
  "supply-5k-lend": 100,
  "borrow-2k": 120,
  "open-2x-multiply": 90,
  "use-3-products": 150,
  "use-curve-position": 80,
  "use-uniswap-v4-position": 80,
  "maintain-hf-above-2": 110,
  "keep-multiply-safe": 110,
  "complete-5-borrow-repay-cycles": 95,
  "complete-3-multiply-deleverage-cycles": 105,
  "activate-5-markets": 130,
  "claim-rewards-5-times": 80,
  "4-week-activity-streak": 140,
  "grow-portfolio-10k": 180,
  "open-8-active-positions": 220,
  "share-referral-link": 15,
  "invite-first-wallet": 40,
  "first-funded-referral": 70,
  "bring-3-active-users": 140,
  "bring-5-active-users": 220,
  "referral-cohort-25k": 260,
  "referral-streak": 240,
  "avana-ambassador": 400,
}

/** Quests currently rendered by buildDefaultRewardsCatalog; retired ids remain above only for history. */
export const ACTIVE_REWARDS_TASK_IDS = new Set([
  "connect-wallet",
  "review-risk-basics",
  "run-first-simulation",
  "first-lend-deposit",
  "supply-5k-lend",
  "favorite-market",
  "first-borrow",
  "first-repay",
  "use-curve-position",
  "first-multiply",
  "first-deleverage",
  "use-uniswap-v4-position",
  "share-referral-link",
  "invite-first-wallet",
  "bring-3-active-users",
])

/** Sandbox AVA→USD conversion (1:1 — see file header). */
export const AVA_USD_PRICE = 1

/**
 * Compute the authoritative USD payout for a set of claimed task ids. Throws
 * `UNKNOWN_TASK_ID` on any id the catalog doesn't recognise so a caller can't
 * mint a payout by claiming a fake task. Empty input returns 0.
 */
export function deriveClaimAmountUsd(taskIds: readonly string[]): number {
  let totalAva = 0
  for (const id of taskIds) {
    const amount = REWARDS_CATALOG_AVA[id]
    if (amount === undefined) {
      throw codedError(`UNKNOWN_TASK_ID: ${id}`)
    }
    if (!ACTIVE_REWARDS_TASK_IDS.has(id)) {
      throw codedError(`INACTIVE_TASK_ID: ${id}`)
    }
    totalAva += amount
  }
  return totalAva * AVA_USD_PRICE
}
