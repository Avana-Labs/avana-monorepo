import type { LendAction, LendMarket, LendSystemState } from "@/app/lib/lend-engine"
import { getWalletLendAssets } from "@/app/lib/data/mock/wallet/portfolio/lend-wallet-assets"
import { buildLendCatalogMarketsRecord } from "./catalog"
import { resolveLendMarketId } from "./catalog"

function buildMockWalletBalances(walletId: string) {
  const balances: Record<string, number> = {}
  for (const token of getWalletLendAssets(walletId)) {
    balances[resolveLendMarketId(token.symbol)] = token.balance
  }
  return {
    [walletId]: balances,
  }
}

function seedPosition(
  state: LendSystemState,
  walletId: string,
  marketId: string,
  principalAmount: number,
  openedDaysAgo = 14,
) {
  const market = state.markets[marketId]
  if (!market) return

  const positionId = `${walletId}:${market.marketId}`
  const interestEarned = principalAmount * market.supplyApy * (openedDaysAgo / 365)
  const currentSuppliedAmount = principalAmount + interestEarned

  state.positions[positionId] = {
    positionId,
    walletId,
    marketId: market.marketId,
    asset: market.asset.symbol,
    principalAmount,
    scaledBalance: principalAmount,
    liquidityIndexAtLastAction: market.liquidityIndex,
    currentSuppliedAmount,
    interestEarned,
    rewardsEarnedUsd: interestEarned * market.assetPriceUsd * (market.rewardsApy / market.supplyApy) * 0.25,
    suppliedValueUsd: currentSuppliedAmount * market.assetPriceUsd,
    openedAt: state.now - openedDaysAgo * 86_400_000,
    updatedAt: state.now - 3_600_000,
    status: "active",
  }
}

export function buildMockLendSystemState(walletId = "demo-wallet", now = Date.UTC(2026, 5, 19)): LendSystemState {
  return {
    now,
    markets: buildLendCatalogMarketsRecord(now),
    positions: {},
    walletBalances: buildMockWalletBalances(walletId),
    transactions: [],
  }
}

export function buildLendCatalogBaselineState(walletId = "catalog", now = Date.UTC(2026, 5, 19)): LendSystemState {
  return buildMockLendSystemState(walletId, now)
}

export function buildMockLendMarket(marketId: string): LendMarket {
  const state = buildMockLendSystemState()
  const market = state.markets[marketId]
  if (!market) throw new Error(`Unknown lend market ${marketId}`)
  return market
}

export function buildMockLendSystemStateWithSeedPosition(walletId = "demo-wallet"): LendSystemState {
  const state = buildMockLendSystemState(walletId)
  seedPosition(state, walletId, "eth", 10, 14)
  return state
}

export function buildDemoLendSystemState(walletId = "demo-wallet"): LendSystemState {
  const state = buildMockLendSystemState(walletId)
  seedPosition(state, walletId, "eth", 1.28, 21)
  seedPosition(state, walletId, "usdc", 4200, 18)
  seedPosition(state, walletId, "gho", 2500, 30)
  return state
}

export type { LendAction, LendSystemState }
