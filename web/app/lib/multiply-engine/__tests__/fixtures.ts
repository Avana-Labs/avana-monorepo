import type { MultiplyMarketRecord, MultiplySystemState } from "@/app/lib/multiply-engine"
import { MULTIPLY_MARKET_CATALOG } from "@/app/lib/multiply-system/catalog"

const EXAMPLE_ETH_USDT_MARKET_ID = "eth-usdt"

export const EXAMPLE_ETH_USDT_MARKET: MultiplyMarketRecord =
  MULTIPLY_MARKET_CATALOG.find((market) => market.id === EXAMPLE_ETH_USDT_MARKET_ID) ?? MULTIPLY_MARKET_CATALOG[0]!

export function makeExampleMultiplySystemState(): MultiplySystemState {
  const market = EXAMPLE_ETH_USDT_MARKET
  const walletId = "wallet-1"
  const positionId = `${walletId}:${market.id}`
  const collateralAmount = 1
  const collateralValueUsd = collateralAmount * market.collateralAsset.priceUsd
  const multiplier = 2.2
  const debtValueUsd = collateralValueUsd * (multiplier - 1)

  return {
    now: Date.UTC(2026, 5, 19),
    markets: Object.fromEntries(MULTIPLY_MARKET_CATALOG.map((entry) => [entry.id, entry])),
    positions: {
      [positionId]: {
        id: positionId,
        walletId,
        marketId: market.id,
        collateralAmount: collateralAmount * multiplier,
        collateralValueUsd: collateralValueUsd * multiplier,
        debtValueUsd,
        multiplier,
        ltv: debtValueUsd / (collateralValueUsd * multiplier),
        healthFactor: (collateralValueUsd * multiplier * market.risk.liquidationThreshold) / debtValueUsd,
        liquidationPrice: debtValueUsd / (collateralAmount * multiplier * market.risk.liquidationThreshold),
        netApy: 0.03,
        openedAt: Date.UTC(2026, 5, 1),
        lastUpdatedAt: Date.UTC(2026, 5, 10),
      },
    },
    transactions: [],
  }
}
