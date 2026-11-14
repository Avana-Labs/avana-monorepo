import { createDataSourceAdapter } from "@/app/lib/data/core/source-runtime"
import type { PortfolioPageSource } from "@/app/lib/data/providers/portfolio/source"
import { getWalletActivity } from "./activity"
import { getWalletDebts } from "./debts"
import {
  getWalletCollaterals,
  getWalletMultiplyCreditLines,
  getWalletMultiplyCollaterals,
  getWalletMultiplyPositions,
  getWalletOpenOrders,
  getWalletTwapOrders,
} from "./positions"
import { getDefaultWalletProfileId, getWalletProfile } from "./profiles"
import { getWalletRewards } from "./rewards"
import { getWalletSnapshots } from "./snapshots"
import { WALLET_STRATEGY_BUCKETS } from "./strategies"
import { getWalletSupplies } from "./supplies"

const mockPortfolioPageAdapter = createDataSourceAdapter({
  id: "portfolio-mock",
  label: "Portfolio page mock source",
  mode: "mock",
  supportsPagination: true,
})

export const mockPortfolioPageSource: PortfolioPageSource = {
  adapter: mockPortfolioPageAdapter,
  getDefaultWalletProfileId() {
    return getDefaultWalletProfileId()
  },
  async getPortfolioPageRecords(walletProfileId: string) {
    const walletProfile = getWalletProfile(walletProfileId)

    return {
      fetchedAt: new Date().toISOString(),
      pageInfo: {
        nextCursor: null,
        hasMore: false,
      },
      data: {
        walletProfile,
        snapshots: getWalletSnapshots(walletProfile.id),
        supplies: getWalletSupplies(walletProfile.id),
        debts: getWalletDebts(walletProfile.id),
        collaterals: getWalletCollaterals(walletProfile.id),
        multiplyCreditLines: getWalletMultiplyCreditLines(walletProfile.id),
        multiplyCollaterals: getWalletMultiplyCollaterals(walletProfile.id),
        multiplyPositions: getWalletMultiplyPositions(walletProfile.id),
        openOrders: getWalletOpenOrders(walletProfile.id),
        twapOrders: getWalletTwapOrders(walletProfile.id),
        activity: getWalletActivity(walletProfile.id),
        strategies: WALLET_STRATEGY_BUCKETS,
        rewards: getWalletRewards(walletProfile.id),
      },
    }
  },
}
