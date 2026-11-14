import { canonicalPriceUsd } from "./canonical"
import { PRICE_FIXTURE } from "./price-fixture"

/**
 * Single source of truth for sandbox baseline token prices (USD).
 *
 * WHY THIS EXISTS: lend, multiply, swap, and borrow each used to carry their own
 * hardcoded price map, and they disagreed badly — ETH read $3,500 on lend/multiply
 * but $1,934 on swap and ~$2,021 on borrow, so the SAME token balance showed a
 * different USD value depending on which screen you were on (e.g. dashboard Lend
 * vs Wallet). These are the realistic-tier values, aligned with the swap/wallet
 * surface and the live DefiLlama oracle used on detail pages (ETH ~$1.9k, not $3.5k).
 *
 * Any product that needs a static USD price for a symbol MUST read it from here.
 * Keys are UPPERCASE symbols. The detail-page single-asset "Price" quick-stat tile also
 * reads this baseline (via injectBaselinePrice in detail-page/live-detail-helpers), so the
 * tile agrees with the collateral valuation shown beside it instead of drifting to the live
 * oracle. The live Convex `tokenPrices` (DefiLlama) via token-prices-context is still used
 * for the borrow-list pair exchange-rate cells, which are intentionally live.
 */
// Single source of the values: the deterministic PRICE_FIXTURE (see price-fixture.ts). Kept as a
// named export for existing callers; the canonical store overlays these with live oracle prices.
export const SANDBOX_BASELINE_PRICES_USD: Record<string, number> = PRICE_FIXTURE

/**
 * Guaranteed-number price for engine code that cannot render "unavailable" mid-calculation. Reads
 * the live canonical store (fixture overlaid by the oracle) and falls back to $1 only for a symbol
 * neither source covers. Surfaces that CAN show unavailable use `canonicalPriceUsd` (strict) instead.
 */
export function sandboxBaselinePriceUsd(symbol: string): number {
  return canonicalPriceUsd(symbol) ?? 1
}
