import type { PortfolioRewardsRecord } from "@/app/lib/data/providers/portfolio/source"

const WALLET_REWARDS: PortfolioRewardsRecord[] = [
  {
    walletProfileId: "demo-wallet",
    claimableUsd: 8_420,
    earnedUsd: 25_600,
    settledUsd: 22_010,
    pendingUsd: 3_590,
  },
]

export function getWalletRewards(walletProfileId: string) {
  return WALLET_REWARDS.find((record) => record.walletProfileId === walletProfileId) ?? WALLET_REWARDS[0]
}
