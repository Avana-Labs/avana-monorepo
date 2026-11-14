import { registryBaselinePrices } from "@/app/lib/tokens/registry"

/**
 * Deterministic token USD price fixture — the SINGLE seed/fallback for the canonical price store
 * (see canonical.ts). It exists so tests, local dev, SSR, and offline renders have stable,
 * deterministic prices; at runtime the live Convex oracle (convex/prices.ts, DefiLlama) overlays
 * these values and is the source of truth when connected.
 *
 * This is NOT a hand-maintained "production price" — it is a fixed snapshot. Previously these
 * numbers were duplicated across three hand-synced maps (sandbox-baseline-prices, the Convex
 * onboarding/umbrella copies); this module is the app-side single source. Keys are UPPERCASE
 * symbols. Do NOT add live-moving values here — real prices come from the oracle.
 */
export const PRICE_FIXTURE: Record<string, number> = {
  // New tokens (tokenized stocks, …) are declared once in the token registry and spread in here;
  // any hand-set fixture below wins on a key collision.
  ...registryBaselinePrices(),
  // Stablecoins
  USDC: 1,
  USDT: 1,
  DAI: 1,
  GHO: 1,
  CRVUSD: 1,
  FRXUSD: 1,
  USDG: 1,
  RLUSD: 1,
  EURC: 1.08,
  // ETH and liquid-staking derivatives (ratios to ETH preserved from the prior maps)
  ETH: 1934,
  WETH: 1934,
  STETH: 1930,
  WSTETH: 2100,
  RETH: 2045,
  CBETH: 1990,
  WEETH: 2017,
  // BTC family
  BTC: 65000,
  WBTC: 65000,
  CBBTC: 65000,
  // Governance / other majors
  AAVE: 105,
  UNI: 12,
  CRV: 0.5,
  LDO: 2,
  BAL: 3.3,
  GNO: 220,
  AERO: 2.25,
  ARB: 0.6,
  OP: 1.46,
  LINK: 18,
}
