import type { MultiplyMarketRecord, MultiplyRiskTier } from "@/app/lib/multiply-engine/types"
import {
  calculateNetApy,
  calculateSafeMaxMultiplier,
  calculateTheoreticalMaxMultiplier,
} from "@/app/lib/multiply-engine/formulas"
import { MULTIPLY_CATALOG_LEVERAGE_SCALE } from "@/app/lib/multiply-system/leverage-limits"
import { MULTIPLY_COLLATERAL_FACTORS } from "@/app/lib/multiply-sim"
import { SANDBOX_BASELINE_PRICES_USD as ASSET_PRICES_USD } from "@/app/lib/prices/sandbox-baseline-prices"
import { canonicalTokenSymbol } from "@/app/lib/tokens/canonical-symbol"

type CatalogSeed = {
  id: string
  rank: number
  collateral: string
  collateralName: string
  borrow: string
  borrowName: string
  supplyApy: number
  borrowApy: number
  estimatedMaxApy: number
  maxLtv: number
  liquidationThreshold: number
  hardMaxMultiplier: number
  publicMaxMultiplier: number
  minHealthFactor: number
  availableLiquidityUsd: number
  riskTier: MultiplyRiskTier
  collateralPriceUsd: number
  borrowPriceUsd: number
  featured?: boolean
}

const CATALOG_SEEDS: CatalogSeed[] = [
  {
    id: "aave-gho",
    rank: 1,
    collateral: "AAVE",
    collateralName: "Aave",
    borrow: "GHO",
    borrowName: "GHO",
    supplyApy: 0.076,
    borrowApy: 0.039,
    estimatedMaxApy: 0.1056,
    maxLtv: 0.5,
    liquidationThreshold: 0.65,
    hardMaxMultiplier: 2,
    publicMaxMultiplier: 1.8,
    minHealthFactor: 1.5,
    availableLiquidityUsd: 8_400_000,
    riskTier: "high",
    collateralPriceUsd: ASSET_PRICES_USD.AAVE,
    borrowPriceUsd: 1,
  },
  {
    id: "cbbtc-wbtc",
    rank: 2,
    collateral: "cbBTC",
    collateralName: "Coinbase Wrapped BTC",
    borrow: "WBTC",
    borrowName: "Wrapped BTC",
    supplyApy: 0.0425,
    borrowApy: 0.037,
    estimatedMaxApy: 0.0535,
    maxLtv: 0.82,
    liquidationThreshold: 0.88,
    hardMaxMultiplier: 5.56,
    publicMaxMultiplier: 3,
    minHealthFactor: 1.25,
    availableLiquidityUsd: 5_800_000,
    riskTier: "medium",
    collateralPriceUsd: ASSET_PRICES_USD.CBBTC,
    borrowPriceUsd: ASSET_PRICES_USD.WBTC,
  },
  {
    id: "cbbtc-usdt",
    rank: 3,
    collateral: "cbBTC",
    collateralName: "Coinbase Wrapped BTC",
    borrow: "USDT",
    borrowName: "Tether",
    supplyApy: 0.0425,
    borrowApy: 0.048,
    estimatedMaxApy: 0.037,
    maxLtv: 0.7,
    liquidationThreshold: 0.78,
    hardMaxMultiplier: 3.33,
    publicMaxMultiplier: 2,
    minHealthFactor: 1.35,
    availableLiquidityUsd: 6_900_000,
    riskTier: "medium",
    collateralPriceUsd: ASSET_PRICES_USD.CBBTC,
    borrowPriceUsd: 1,
  },
  {
    id: "cbeth-eth",
    rank: 4,
    collateral: "cbETH",
    collateralName: "Coinbase Wrapped Staked ETH",
    borrow: "ETH",
    borrowName: "Ether",
    supplyApy: 0.0462,
    borrowApy: 0.04,
    estimatedMaxApy: 0.0648,
    maxLtv: 0.86,
    liquidationThreshold: 0.91,
    hardMaxMultiplier: 7.14,
    publicMaxMultiplier: 4,
    minHealthFactor: 1.2,
    availableLiquidityUsd: 5_000_000,
    riskTier: "low",
    collateralPriceUsd: ASSET_PRICES_USD.CBETH,
    borrowPriceUsd: ASSET_PRICES_USD.ETH,
  },
  {
    id: "crv-crvusd",
    rank: 5,
    collateral: "CRV",
    collateralName: "Curve DAO Token",
    borrow: "crvUSD",
    borrowName: "crvUSD",
    supplyApy: 0.0545,
    borrowApy: 0.044,
    estimatedMaxApy: 0.0608,
    maxLtv: 0.45,
    liquidationThreshold: 0.6,
    hardMaxMultiplier: 1.82,
    publicMaxMultiplier: 1.6,
    minHealthFactor: 1.55,
    availableLiquidityUsd: 4_600_000,
    riskTier: "high",
    collateralPriceUsd: ASSET_PRICES_USD.CRV,
    borrowPriceUsd: 1,
  },
  {
    id: "crvusd-usdt",
    rank: 6,
    collateral: "crvUSD",
    collateralName: "crvUSD",
    borrow: "USDT",
    borrowName: "Tether",
    supplyApy: 0.044,
    borrowApy: 0.048,
    estimatedMaxApy: 0.03,
    maxLtv: 0.85,
    liquidationThreshold: 0.9,
    hardMaxMultiplier: 6.67,
    publicMaxMultiplier: 4.5,
    minHealthFactor: 1.15,
    availableLiquidityUsd: 7_200_000,
    riskTier: "low",
    collateralPriceUsd: 1,
    borrowPriceUsd: 1,
  },
  {
    id: "dai-usdt",
    rank: 7,
    collateral: "DAI",
    collateralName: "Dai",
    borrow: "USDT",
    borrowName: "Tether",
    supplyApy: 0.0401,
    borrowApy: 0.048,
    estimatedMaxApy: 0.0164,
    maxLtv: 0.83,
    liquidationThreshold: 0.88,
    hardMaxMultiplier: 5.88,
    publicMaxMultiplier: 4,
    minHealthFactor: 1.18,
    availableLiquidityUsd: 7_200_000,
    riskTier: "low",
    collateralPriceUsd: 1,
    borrowPriceUsd: 1,
  },
  {
    id: "dai-gho",
    rank: 8,
    collateral: "DAI",
    collateralName: "Dai",
    borrow: "GHO",
    borrowName: "GHO",
    supplyApy: 0.0401,
    borrowApy: 0.039,
    estimatedMaxApy: 0.044,
    maxLtv: 0.84,
    liquidationThreshold: 0.89,
    hardMaxMultiplier: 6.25,
    publicMaxMultiplier: 4.5,
    minHealthFactor: 1.18,
    availableLiquidityUsd: 9_100_000,
    riskTier: "low",
    collateralPriceUsd: 1,
    borrowPriceUsd: 1,
  },
  {
    id: "eth-wsteth",
    rank: 9,
    collateral: "ETH",
    collateralName: "Ether",
    borrow: "wstETH",
    borrowName: "Wrapped stETH",
    supplyApy: 0.0382,
    borrowApy: 0.034,
    estimatedMaxApy: 0.0466,
    maxLtv: 0.78,
    liquidationThreshold: 0.84,
    hardMaxMultiplier: 4.55,
    publicMaxMultiplier: 3,
    minHealthFactor: 1.25,
    availableLiquidityUsd: 6_600_000,
    riskTier: "medium",
    collateralPriceUsd: ASSET_PRICES_USD.ETH,
    borrowPriceUsd: ASSET_PRICES_USD.WSTETH,
  },
  {
    id: "eth-usdt",
    rank: 10,
    collateral: "ETH",
    collateralName: "Ether",
    borrow: "USDT",
    borrowName: "Tether",
    supplyApy: 0.0382,
    borrowApy: 0.048,
    estimatedMaxApy: 0.0264,
    maxLtv: 0.73,
    liquidationThreshold: 0.8,
    hardMaxMultiplier: 3.7,
    publicMaxMultiplier: 2.2,
    minHealthFactor: 1.35,
    availableLiquidityUsd: 7_200_000,
    riskTier: "medium",
    collateralPriceUsd: ASSET_PRICES_USD.ETH,
    borrowPriceUsd: 1,
    featured: true,
  },
  {
    id: "eth-gho",
    rank: 11,
    collateral: "ETH",
    collateralName: "Ether",
    borrow: "GHO",
    borrowName: "GHO",
    supplyApy: 0.0382,
    borrowApy: 0.039,
    estimatedMaxApy: 0.0371,
    maxLtv: 0.74,
    liquidationThreshold: 0.81,
    hardMaxMultiplier: 3.85,
    publicMaxMultiplier: 2.4,
    minHealthFactor: 1.3,
    availableLiquidityUsd: 9_100_000,
    riskTier: "medium",
    collateralPriceUsd: ASSET_PRICES_USD.ETH,
    borrowPriceUsd: 1,
  },
  {
    id: "eurc-gho",
    rank: 12,
    collateral: "EURC",
    collateralName: "Euro Coin",
    borrow: "GHO",
    borrowName: "GHO",
    supplyApy: 0.0049,
    borrowApy: 0.039,
    estimatedMaxApy: -0.0292,
    maxLtv: 0.7,
    liquidationThreshold: 0.78,
    hardMaxMultiplier: 3.33,
    publicMaxMultiplier: 2,
    minHealthFactor: 1.35,
    availableLiquidityUsd: 9_100_000,
    riskTier: "medium",
    collateralPriceUsd: ASSET_PRICES_USD.EURC,
    borrowPriceUsd: 1,
  },
  {
    id: "reth-eth",
    rank: 13,
    collateral: "rETH",
    collateralName: "Rocket Pool ETH",
    borrow: "ETH",
    borrowName: "Ether",
    supplyApy: 0.0487,
    borrowApy: 0.04,
    estimatedMaxApy: 0.0792,
    maxLtv: 0.88,
    liquidationThreshold: 0.92,
    hardMaxMultiplier: 8.33,
    publicMaxMultiplier: 4.5,
    minHealthFactor: 1.2,
    availableLiquidityUsd: 5_000_000,
    riskTier: "low",
    collateralPriceUsd: ASSET_PRICES_USD.RETH,
    borrowPriceUsd: ASSET_PRICES_USD.ETH,
  },
  {
    id: "steth-eth",
    rank: 14,
    collateral: "stETH",
    collateralName: "Lido Staked ETH",
    borrow: "ETH",
    borrowName: "Ether",
    supplyApy: 0.0414,
    borrowApy: 0.04,
    estimatedMaxApy: 0.0456,
    maxLtv: 0.87,
    liquidationThreshold: 0.91,
    hardMaxMultiplier: 7.69,
    publicMaxMultiplier: 4,
    minHealthFactor: 1.2,
    availableLiquidityUsd: 5_000_000,
    riskTier: "low",
    collateralPriceUsd: ASSET_PRICES_USD.STETH,
    borrowPriceUsd: ASSET_PRICES_USD.ETH,
  },
  {
    id: "uni-usdc",
    rank: 15,
    collateral: "UNI",
    collateralName: "Uniswap",
    borrow: "USDC",
    borrowName: "USD Coin",
    supplyApy: 0.064,
    borrowApy: 0.052,
    estimatedMaxApy: 0.0724,
    maxLtv: 0.5,
    liquidationThreshold: 0.65,
    hardMaxMultiplier: 2,
    publicMaxMultiplier: 1.7,
    minHealthFactor: 1.5,
    availableLiquidityUsd: 9_400_000,
    riskTier: "high",
    collateralPriceUsd: ASSET_PRICES_USD.UNI,
    borrowPriceUsd: 1,
  },
  {
    id: "usdc-usdt",
    rank: 16,
    collateral: "USDC",
    collateralName: "USD Coin",
    borrow: "USDT",
    borrowName: "Tether",
    supplyApy: 0.052,
    borrowApy: 0.048,
    estimatedMaxApy: 0.068,
    maxLtv: 0.87,
    liquidationThreshold: 0.92,
    hardMaxMultiplier: 7.69,
    publicMaxMultiplier: 5,
    minHealthFactor: 1.12,
    availableLiquidityUsd: 7_200_000,
    riskTier: "low",
    collateralPriceUsd: 1,
    borrowPriceUsd: 1,
  },
  {
    id: "usdc-gho",
    rank: 17,
    collateral: "USDC",
    collateralName: "USD Coin",
    borrow: "GHO",
    borrowName: "GHO",
    supplyApy: 0.052,
    borrowApy: 0.039,
    estimatedMaxApy: 0.1105,
    maxLtv: 0.88,
    liquidationThreshold: 0.92,
    hardMaxMultiplier: 8.33,
    publicMaxMultiplier: 5.5,
    minHealthFactor: 1.12,
    availableLiquidityUsd: 9_100_000,
    riskTier: "low",
    collateralPriceUsd: 1,
    borrowPriceUsd: 1,
    featured: true,
  },
  {
    id: "wbtc-cbbtc",
    rank: 18,
    collateral: "WBTC",
    collateralName: "Wrapped BTC",
    borrow: "cbBTC",
    borrowName: "Coinbase Wrapped BTC",
    supplyApy: 0.0348,
    borrowApy: 0.039,
    estimatedMaxApy: 0.0264,
    maxLtv: 0.8,
    liquidationThreshold: 0.86,
    hardMaxMultiplier: 5,
    publicMaxMultiplier: 3,
    minHealthFactor: 1.25,
    availableLiquidityUsd: 3_400_000,
    riskTier: "medium",
    collateralPriceUsd: ASSET_PRICES_USD.WBTC,
    borrowPriceUsd: ASSET_PRICES_USD.CBBTC,
  },
  {
    id: "wbtc-usdt",
    rank: 19,
    collateral: "WBTC",
    collateralName: "Wrapped BTC",
    borrow: "USDT",
    borrowName: "Tether",
    supplyApy: 0.0348,
    borrowApy: 0.048,
    estimatedMaxApy: 0.0216,
    maxLtv: 0.7,
    liquidationThreshold: 0.78,
    hardMaxMultiplier: 3.33,
    publicMaxMultiplier: 2,
    minHealthFactor: 1.35,
    availableLiquidityUsd: 7_200_000,
    riskTier: "medium",
    collateralPriceUsd: ASSET_PRICES_USD.WBTC,
    borrowPriceUsd: 1,
  },
  {
    id: "wsteth-eth",
    rank: 20,
    collateral: "wstETH",
    collateralName: "Wrapped stETH",
    borrow: "ETH",
    borrowName: "Ether",
    supplyApy: 0.0514,
    borrowApy: 0.04,
    estimatedMaxApy: 0.097,
    maxLtv: 0.9,
    liquidationThreshold: 0.93,
    hardMaxMultiplier: 10,
    publicMaxMultiplier: 5,
    minHealthFactor: 1.15,
    availableLiquidityUsd: 5_000_000,
    riskTier: "low",
    collateralPriceUsd: ASSET_PRICES_USD.WSTETH,
    borrowPriceUsd: ASSET_PRICES_USD.ETH,
    featured: true,
  },
]

function toMarketRecord(seed: CatalogSeed): MultiplyMarketRecord {
  const publicMaxMultiplier = seed.publicMaxMultiplier * MULTIPLY_CATALOG_LEVERAGE_SCALE
  const hardMaxMultiplier = seed.hardMaxMultiplier * MULTIPLY_CATALOG_LEVERAGE_SCALE
  const theoreticalMaxMultiplier = calculateTheoreticalMaxMultiplier(seed.maxLtv)
  // Use the real (un-scaled) public cap here: recommendedMaxMultiplier must not
  // exceed the leverage the action-page slider actually lets a user select
  // (resolveMultiplyMarketMaxLeverage divides the inflated catalog label back down).
  const safeMaxMultiplier = calculateSafeMaxMultiplier({
    publicMaxMultiplier: seed.publicMaxMultiplier,
    theoreticalMaxMultiplier,
    minHealthFactor: seed.minHealthFactor,
    liquidationThreshold: seed.liquidationThreshold,
  })
  // Normalize the declared collateral symbol to its canonical map key so the per-token factor resolves
  // regardless of the seed's casing (STETH → stETH, CBBTC → cbBTC). The old `as` cast silently let a
  // cased mismatch fall through to seed.maxLtv for the 5 mixed-case symbols (stETH/wstETH/rETH/cbBTC/cbETH).
  const collateralKey = canonicalTokenSymbol(seed.collateral)
  // The collateral factor (max borrow ratio) must sit strictly below the
  // liquidation threshold — a market can't let you borrow up to the point it
  // liquidates. The per-token MULTIPLY_COLLATERAL_FACTORS override could exceed a
  // market's LT (e.g. AAVE CF 70% vs GHO LT 65%), so clamp it below LT.
  const rawCollateralFactor = (collateralKey ? MULTIPLY_COLLATERAL_FACTORS[collateralKey] : undefined) ?? seed.maxLtv
  const collateralFactor = Math.min(rawCollateralFactor, seed.liquidationThreshold - 0.01)

  return {
    id: seed.id,
    rank: seed.rank,
    collateralAsset: {
      symbol: seed.collateral,
      name: seed.collateralName,
      apy: seed.supplyApy,
      priceUsd: seed.collateralPriceUsd,
    },
    borrowAsset: {
      symbol: seed.borrow,
      name: seed.borrowName,
      borrowApy: seed.borrowApy,
      priceUsd: seed.borrowPriceUsd,
    },
    risk: {
      maxLtv: seed.maxLtv,
      collateralFactor,
      liquidationThreshold: seed.liquidationThreshold,
      hardMaxMultiplier,
      publicMaxMultiplier,
      recommendedMaxMultiplier: safeMaxMultiplier,
      minHealthFactor: seed.minHealthFactor,
      riskTier: seed.riskTier,
    },
    economics: {
      estimatedMaxApy: seed.estimatedMaxApy,
      supplyApy: seed.supplyApy,
      borrowApy: seed.borrowApy,
      availableLiquidityUsd: seed.availableLiquidityUsd,
    },
    ui: {
      status: "active",
      featured: seed.featured,
    },
  }
}

export const MULTIPLY_MARKET_CATALOG: MultiplyMarketRecord[] = CATALOG_SEEDS.map(toMarketRecord)

// Seed-time invariant: a valid market always has liquidationThreshold > collateralFactor.
// The clamp above guarantees it; this guard fails loudly if a future catalog edit
// (or a bad per-token override) ever reintroduces an impossible CF ≥ LT market.
for (const market of MULTIPLY_MARKET_CATALOG) {
  if (market.risk.liquidationThreshold <= market.risk.collateralFactor) {
    throw new Error(
      `Invalid multiply market "${market.id}": liquidationThreshold (${market.risk.liquidationThreshold}) must exceed collateralFactor (${market.risk.collateralFactor}).`,
    )
  }
}

export function getMultiplyMarketById(marketId: string) {
  return MULTIPLY_MARKET_CATALOG.find((market) => market.id === marketId) ?? null
}

export function buildMultiplyCatalogMarketsRecord() {
  const markets: Record<string, MultiplyMarketRecord> = {}
  for (const market of MULTIPLY_MARKET_CATALOG) {
    markets[market.id] = market
  }
  return markets
}

const MULTIPLY_MARKET_BY_ID = new Map(MULTIPLY_MARKET_CATALOG.map((market) => [market.id, market]))

/**
 * A loop's Net APY in PERCENT, recomputed from the catalog market economics with the same
 * formula the Multiply UI uses (`revalueMultiplyPosition`). Server readers must use this
 * instead of the persisted `positions.netApyPct`, which the sandbox writes as 0 at open and,
 * when it is set, stores as a fraction. Returns null for an unknown market slug.
 */
export function catalogMultiplyNetApyPct(
  marketSlug: string,
  collateralValueUsd: number,
  debtValueUsd: number,
): number | null {
  const market = MULTIPLY_MARKET_BY_ID.get(marketSlug)
  if (!market) return null
  return (
    calculateNetApy({
      supplyApy: market.economics.supplyApy,
      borrowApy: market.economics.borrowApy,
      finalCollateralValueUsd: collateralValueUsd,
      debtValueUsd,
      initialCollateralValueUsd: Math.max(1, collateralValueUsd - debtValueUsd),
    }) * 100
  )
}
