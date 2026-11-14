import { REWARDS_PROMO_TABS } from "@/app/lib/data/rewards/catalog"
import type { RewardsPromoTabId, RewardsQuest } from "@/app/lib/data/rewards/catalog"

export type RewardsPageData = {
  walletProfileId: string
  promoTabs: ReadonlyArray<(typeof REWARDS_PROMO_TABS)[number]>
  questsByTab: Record<RewardsPromoTabId, RewardsQuest[]>
}
