import { formatCompactUsd } from "@/app/lib/borrow-sim"
import { getLocalAssetIcon } from "@/app/lib/local-asset-icons"
import { calculateMaxLeverageApy } from "@/app/lib/multiply-engine/formulas"
import { MULTIPLY_ACTION_MAX_LEVERAGE } from "@/app/lib/multiply-system/leverage-limits"
import { formatPercent } from "@/app/lib/format"

export const MULTIPLY_TOKEN_LOGOS = {
  ETH: getLocalAssetIcon("ETH"),
  stETH: getLocalAssetIcon("stETH"),
  wstETH: getLocalAssetIcon("wstETH"),
  rETH: getLocalAssetIcon("rETH"),
  cbETH: getLocalAssetIcon("cbETH"),
  USDT: getLocalAssetIcon("USDT"),
  USDC: getLocalAssetIcon("USDC"),
  DAI: getLocalAssetIcon("DAI"),
  GHO: getLocalAssetIcon("GHO"),
  crvUSD: getLocalAssetIcon("crvUSD"),
  EURC: getLocalAssetIcon("EURC"),
  WBTC: getLocalAssetIcon("WBTC"),
  cbBTC: getLocalAssetIcon("cbBTC"),
  AAVE: getLocalAssetIcon("AAVE"),
  UNI: getLocalAssetIcon("UNI"),
  CRV: getLocalAssetIcon("CRV"),
} as const

export const MULTIPLY_TOKEN_SUPPLY_APYS: Partial<Record<keyof typeof MULTIPLY_TOKEN_LOGOS, string>> = {
  ETH: "3.82%",
  stETH: "4.14%",
  wstETH: "5.14%",
  rETH: "4.87%",
  cbETH: "4.62%",
  USDC: "5.20%",
  USDT: "4.80%",
  DAI: "4.01%",
  GHO: "2.99%",
  crvUSD: "4.40%",
  EURC: "0.49%",
  WBTC: "3.48%",
  cbBTC: "4.25%",
  AAVE: "7.60%",
  UNI: "6.40%",
  CRV: "5.45%",
}

export const MULTIPLY_TOKEN_BORROW_APYS: Partial<Record<keyof typeof MULTIPLY_TOKEN_LOGOS, string>> = {
  ETH: "4.00%",
  stETH: "3.40%",
  wstETH: "3.40%",
  rETH: "3.50%",
  cbETH: "3.60%",
  USDC: "5.20%",
  USDT: "4.80%",
  DAI: "5.70%",
  GHO: "3.90%",
  crvUSD: "4.40%",
  EURC: "4.10%",
  WBTC: "3.70%",
  cbBTC: "3.90%",
  AAVE: "4.50%",
  UNI: "4.20%",
  CRV: "5.10%",
}

export const MULTIPLY_TOKEN_AVAILABLE_USD: Partial<Record<keyof typeof MULTIPLY_TOKEN_LOGOS, number>> = {
  ETH: 5_000_000,
  stETH: 7_500_000,
  wstETH: 6_600_000,
  rETH: 3_100_000,
  cbETH: 2_400_000,
  USDT: 7_200_000,
  USDC: 9_900_000,
  DAI: 6_600_000,
  GHO: 9_100_000,
  crvUSD: 5_100_000,
  EURC: 2_500_000,
  WBTC: 6_100_000,
  cbBTC: 3_400_000,
  AAVE: 3_500_000,
  UNI: 2_800_000,
  CRV: 1_900_000,
}

export const MULTIPLY_COLLATERAL_FACTORS: Partial<Record<keyof typeof MULTIPLY_TOKEN_LOGOS, number>> = {
  ETH: 0.8,
  stETH: 0.88,
  wstETH: 0.91,
  rETH: 0.89,
  cbETH: 0.86,
  USDT: 0.85,
  USDC: 0.87,
  DAI: 0.85,
  GHO: 0.78,
  crvUSD: 0.8,
  EURC: 0.75,
  WBTC: 0.8,
  cbBTC: 0.78,
  AAVE: 0.7,
  UNI: 0.68,
  CRV: 0.6,
}

export const MULTIPLY_LIQUIDATION_THRESHOLDS: Partial<Record<keyof typeof MULTIPLY_TOKEN_LOGOS, number>> = {
  ETH: 0.83,
  stETH: 0.9,
  wstETH: 0.93,
  rETH: 0.91,
  cbETH: 0.89,
  USDT: 0.88,
  USDC: 0.9,
  DAI: 0.88,
  GHO: 0.82,
  crvUSD: 0.84,
  EURC: 0.8,
  WBTC: 0.83,
  cbBTC: 0.81,
  AAVE: 0.75,
  UNI: 0.73,
  CRV: 0.68,
}

const MULTIPLY_LOOP_DEFINITIONS: Array<{
  collateral: keyof typeof MULTIPLY_TOKEN_LOGOS
  borrowable: keyof typeof MULTIPLY_TOKEN_LOGOS
}> = [
  { collateral: "wstETH", borrowable: "ETH" },
  { collateral: "stETH", borrowable: "ETH" },
  { collateral: "rETH", borrowable: "ETH" },
  { collateral: "cbETH", borrowable: "ETH" },
  { collateral: "ETH", borrowable: "wstETH" },
  { collateral: "ETH", borrowable: "USDT" },
  { collateral: "ETH", borrowable: "GHO" },
  { collateral: "USDC", borrowable: "USDT" },
  { collateral: "USDC", borrowable: "GHO" },
  { collateral: "DAI", borrowable: "USDT" },
  { collateral: "DAI", borrowable: "GHO" },
  { collateral: "crvUSD", borrowable: "USDT" },
  { collateral: "EURC", borrowable: "GHO" },
  { collateral: "WBTC", borrowable: "cbBTC" },
  { collateral: "WBTC", borrowable: "USDT" },
  { collateral: "cbBTC", borrowable: "WBTC" },
  { collateral: "cbBTC", borrowable: "USDT" },
  { collateral: "AAVE", borrowable: "GHO" },
  { collateral: "UNI", borrowable: "USDC" },
  { collateral: "CRV", borrowable: "crvUSD" },
]

export type MultiplyRewardRow = {
  label: string
  value: string
}

export type MultiplyMarketRow = {
  href: string
  protocol: string
  protocolName?: string
  protocolLogo: string
  asset: string
  assetName?: string
  kind: "Loop"
  apy: string
  apyLabel: string
  partnerRewards?: string
  points?: string
  availablePrimary?: string
  availableSecondary?: string
  rewardRows?: MultiplyRewardRow[]
  waitlistHref?: string
  collateralFactor: number
  liquidationThreshold: number
  capacityFilledPct?: number
}

function parsePct(value?: string) {
  if (!value) return 0
  return Number.parseFloat(value.replace("%", "")) || 0
}

function formatFactor(value: number) {
  return `${value.toFixed(2)}x`
}

/**
 * Largest looped leverage an LT theoretically supports, `1/(1−LT)`, with a degenerate LT
 * (≥ 1 or ≤ 0) collapsing to the global action ceiling instead of a non-finite value. Only a
 * fallback for markets absent from the catalog — catalog markets use publicMaxMultiplier.
 */
function safeTheoreticalMaxLeverage(liquidationThreshold: number): number {
  if (!Number.isFinite(liquidationThreshold) || liquidationThreshold <= 0 || liquidationThreshold >= 1) {
    return MULTIPLY_ACTION_MAX_LEVERAGE
  }
  return Math.min(MULTIPLY_ACTION_MAX_LEVERAGE, 1 / (1 - liquidationThreshold))
}

export function buildMultiplyMarketRow(
  collateral: keyof typeof MULTIPLY_TOKEN_LOGOS,
  borrowable: keyof typeof MULTIPLY_TOKEN_LOGOS,
  overrides?: { liquidationThreshold?: number },
): MultiplyMarketRow | null {
  const supplyApy = parsePct(MULTIPLY_TOKEN_SUPPLY_APYS[collateral])
  const borrowApy = parsePct(MULTIPLY_TOKEN_BORROW_APYS[borrowable])
  const cf = MULTIPLY_COLLATERAL_FACTORS[collateral]
  const lt = overrides?.liquidationThreshold ?? MULTIPLY_LIQUIDATION_THRESHOLDS[collateral]
  const availableUsd = MULTIPLY_TOKEN_AVAILABLE_USD[borrowable]

  if (!cf || lt == null || !availableUsd) return null

  const maxLeverage = safeTheoreticalMaxLeverage(lt)
  // Single loop-APY source: the SAME formula read-model uses for the trending card, so a
  // given leverage always maps to one APY across surfaces (no divergent inline math).
  const maxLoopApy = calculateMaxLeverageApy({
    supplyApy: supplyApy / 100,
    borrowApy: borrowApy / 100,
    safeMaxMultiplier: maxLeverage,
  })
  const id = `${collateral}-${borrowable}`

  return {
    href: `/multiply/markets/${id}`,
    protocol: collateral,
    protocolLogo: MULTIPLY_TOKEN_LOGOS[collateral],
    asset: borrowable,
    kind: "Loop",
    // calculateMaxLeverageApy returns a ratio; formatPct expects percent units.
    apy: formatPercent(maxLoopApy * 100),
    apyLabel: "APY derived from supply and borrow APRs",
    points: formatCompactUsd(availableUsd),
    rewardRows: [
      {
        label: `Collateral factor ${Math.round(cf * 100)}% · Liquidation threshold ${Math.round(lt * 100)}%`,
        value: formatFactor(maxLeverage),
      },
    ],
    collateralFactor: cf,
    liquidationThreshold: lt,
  }
}

export const MULTIPLY_MARKET_ROWS: MultiplyMarketRow[] = MULTIPLY_LOOP_DEFINITIONS.map(({ collateral, borrowable }) =>
  buildMultiplyMarketRow(collateral, borrowable),
).filter((row): row is MultiplyMarketRow => Boolean(row))
