import type { MultiplyAction, MultiplySystemState } from "@/app/lib/multiply-engine"
import { buildMultiplyCatalogMarketsRecord } from "./catalog"
import type { MultiplyRiskSnapshot } from "./contracts"

export type { MultiplyRiskSnapshot }

export function buildMockMultiplySystemState(_walletId = "demo-wallet"): MultiplySystemState {
  return {
    now: Date.UTC(2026, 5, 19),
    markets: buildMultiplyCatalogMarketsRecord(),
    positions: {},
    walletBalancesUsd: { [_walletId]: {} },
    transactions: [],
  }
}

export function buildMultiplyCatalogBaselineState(walletId = "catalog"): MultiplySystemState {
  return buildMockMultiplySystemState(walletId)
}

export function buildMockMultiplySystemStateWithSeedPosition(walletId = "demo-wallet"): MultiplySystemState {
  const state = buildMockMultiplySystemState(walletId)
  const market = state.markets["eth-usdt"]
  if (!market) return state

  const collateralAmount = 1
  const collateralValueUsd = collateralAmount * market.collateralAsset.priceUsd
  const multiplier = 2
  const totalExposure = collateralValueUsd * multiplier
  const debtValueUsd = totalExposure - collateralValueUsd
  const positionId = `${walletId}:${market.id}`

  state.positions[positionId] = {
    id: positionId,
    walletId,
    marketId: market.id,
    collateralAmount: collateralAmount * multiplier,
    collateralValueUsd: totalExposure,
    debtValueUsd,
    multiplier,
    ltv: debtValueUsd / totalExposure,
    healthFactor: (totalExposure * market.risk.liquidationThreshold) / debtValueUsd,
    liquidationPrice: debtValueUsd / (collateralAmount * multiplier * market.risk.liquidationThreshold),
    netApy: 0.03,
    openedAt: state.now - 86_400_000,
    lastUpdatedAt: state.now - 3_600_000,
  }

  return state
}

/**
 * Detect the legacy demo-only ETH/USDT position seeded into fresh local wallets: one position with
 * no matching transaction. Matching this exact shape preserves real persisted positions.
 */
export function isLegacySeedOnlyMultiplyState(state: MultiplySystemState, walletId: string) {
  const positions = Object.values(state.positions)
  if (positions.length !== 1 || state.transactions.length !== 0) return false

  const position = positions[0]
  const market = state.markets["eth-usdt"]
  if (!position || !market) return false

  const inputCollateralUsd = market.collateralAsset.priceUsd
  return (
    position.id === `${walletId}:eth-usdt` &&
    position.walletId === walletId &&
    position.marketId === "eth-usdt" &&
    position.multiplier === 2 &&
    Math.abs(position.collateralAmount - 2) < 1e-9 &&
    Math.abs(position.collateralValueUsd - inputCollateralUsd * 2) < 1e-6 &&
    Math.abs(position.debtValueUsd - inputCollateralUsd) < 1e-6
  )
}

export function buildMockMultiplyRiskSnapshots(state: MultiplySystemState): MultiplyRiskSnapshot[] {
  return Object.values(state.positions).map((position) => ({
    marketId: position.marketId,
    healthFactor: position.healthFactor,
    ltv: position.ltv,
    multiplier: position.multiplier,
    capturedAt: position.lastUpdatedAt,
  }))
}

export type { MultiplyAction, MultiplySystemState }
