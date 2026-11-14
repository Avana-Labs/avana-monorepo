// SEED ONLY — imported by build-seed.ts. Not for UI code.
import { buildInterestRateModelParams } from "@/app/lib/borrow-detail/protocol-parameters"
import { MULTIPLY_MARKET_CATALOG } from "@/app/lib/multiply-system/catalog"
import {
  MULTIPLY_COLLATERAL_FACTORS,
  MULTIPLY_LIQUIDATION_THRESHOLDS,
  MULTIPLY_TOKEN_AVAILABLE_USD,
  MULTIPLY_TOKEN_BORROW_APYS,
  MULTIPLY_TOKEN_LOGOS,
  MULTIPLY_TOKEN_SUPPLY_APYS,
} from "@/app/lib/multiply-sim"

import type { SeedMultiplyAllocationRow, SeedMultiplyIrmRow, SeedMultiplyTokenParamRow } from "../build-seed"

/**
 * Interest-rate-model rows — one per multiply market. `buildInterestRateModelParams`
 * is the same seeded (FNV-1a → mulberry unit) formula the borrow IRM seed rows use
 * in build-seed.ts (`interestRateModelRow` → borrowInterestRateModels), so multiply
 * markets share the borrow-side IRM shape and stay reproducible from just the slug
 * + market borrow APY.
 */
export const MULTIPLY_IRM_SEED_ROWS: SeedMultiplyIrmRow[] = MULTIPLY_MARKET_CATALOG.map((market) => {
  const params = buildInterestRateModelParams(market.id, market.economics.borrowApy * 100)
  return {
    slug: market.id,
    optimalUtilizationPct: params.optimalUtilizationPct,
    slopeBelowOptimalPct: params.slopeBelowOptimalPct,
    slopeAboveOptimalPct: params.slopeAboveOptimalPct,
    baseBorrowRatePct: params.baseBorrowRatePct,
  }
})

/**
 * Allocation rows — the mock has no cross-pool allocation for multiply, so seed
 * one "self" row per market pointing at the market itself (100% share, market's
 * own headline liquidity). Real allocation gets replaced when the multiply engine
 * sums live positions.
 */
export const MULTIPLY_ALLOCATION_SEED_ROWS: SeedMultiplyAllocationRow[] = MULTIPLY_MARKET_CATALOG.map((market) => ({
  marketSlug: market.id,
  rowKey: "self",
  poolSlug: market.id,
  poolName: `${market.collateralAsset.symbol} / ${market.borrowAsset.symbol}`,
  venueLabel: "Avana Multiply",
  sharePct: 100,
  valueUsd: market.economics.availableLiquidityUsd,
  utilizationPct: 0,
  borrowAprPct: market.economics.borrowApy * 100,
  collateralFactorPct: market.risk.maxLtv * 100,
}))

/**
 * Token-parameter rows — one per symbol from the six constant maps in multiply-sim.
 * A row is only emitted when every input map has a value for the symbol (skips the
 * whole row on any gap, so consumers never see a partially-populated token record).
 */
const MULTIPLY_TOKEN_SYMBOLS = [
  "ETH",
  "stETH",
  "wstETH",
  "rETH",
  "cbETH",
  "USDT",
  "USDC",
  "DAI",
  "GHO",
  "crvUSD",
  "EURC",
  "WBTC",
  "cbBTC",
  "AAVE",
  "UNI",
  "CRV",
] as const satisfies ReadonlyArray<keyof typeof MULTIPLY_TOKEN_LOGOS>

function parsePctString(value: string | undefined): number | undefined {
  if (value === undefined) return undefined
  const parsed = Number.parseFloat(value.replace("%", ""))
  return Number.isFinite(parsed) ? parsed : undefined
}

export const MULTIPLY_TOKEN_PARAM_SEED_ROWS: SeedMultiplyTokenParamRow[] = MULTIPLY_TOKEN_SYMBOLS.map(
  (symbol): SeedMultiplyTokenParamRow | null => {
    const supplyApyPct = parsePctString(MULTIPLY_TOKEN_SUPPLY_APYS[symbol])
    const borrowAprPct = parsePctString(MULTIPLY_TOKEN_BORROW_APYS[symbol])
    const availableUsd = MULTIPLY_TOKEN_AVAILABLE_USD[symbol]
    const collateralFactor = MULTIPLY_COLLATERAL_FACTORS[symbol]
    const liquidationThreshold = MULTIPLY_LIQUIDATION_THRESHOLDS[symbol]
    const iconUrl = MULTIPLY_TOKEN_LOGOS[symbol]

    if (
      supplyApyPct === undefined ||
      borrowAprPct === undefined ||
      availableUsd === undefined ||
      collateralFactor === undefined ||
      liquidationThreshold === undefined ||
      iconUrl === undefined
    ) {
      return null
    }

    return {
      symbol,
      supplyApyPct,
      borrowAprPct,
      availableUsd,
      collateralFactorPct: collateralFactor * 100,
      liquidationThresholdPct: liquidationThreshold * 100,
      iconUrl,
    }
  },
).filter((row): row is SeedMultiplyTokenParamRow => row !== null)
