/**
 * The single Avana swap-quote engine. Pure (no Convex/browser imports) so it is the ONE
 * implementation shared by the authoritative server (convex/sandbox/swap.ts getQuote +
 * recordSwap) and the client demo provider (app/lib/swap-system/quote-provider.ts). The
 * server owns the engine; the client never computes a swap with a separate formula.
 *
 * Math (unchanged from the original client MockSwapProvider):
 *   amountUsd   = inputAmount × inputPriceUsd
 *   gross       = amountUsd / outputPriceUsd
 *   fee         = gross × feeBps/10_000
 *   impact      = tiered by amountUsd (0.08 / 0.35 / 1.5 / 5 %) × multiplier
 *   estOutput   = max(0, gross − fee − gross×impact/100)
 *   minOutput   = estOutput × (1 − slippageBps/10_000)
 */

export const SWAP_FEE_BPS = 30
export const SWAP_PROVIDER = "Avana mock router"
export const SWAP_CHAIN_ID = 1
export const SWAP_QUOTE_TTL_MS = 120_000
export const SWAP_NETWORK_FEE_USD = 0.24

export type SwapEngineAsset = { id: string; symbol: string; isLpToken: boolean; isSwapEnabled: boolean }

/**
 * Server-side mirror of the swappable catalog (app/lib/swap-system/catalog.ts SWAP_ASSETS).
 * Only the fields the engine needs — parity with the client list is asserted by
 * convex/swap-catalog-parity.test.ts so the two can't drift.
 */
export const SWAP_ENGINE_ASSETS: readonly SwapEngineAsset[] = [
  { id: "eth", symbol: "ETH", isLpToken: false, isSwapEnabled: true },
  { id: "usdc", symbol: "USDC", isLpToken: false, isSwapEnabled: true },
  { id: "gho", symbol: "GHO", isLpToken: false, isSwapEnabled: true },
  { id: "wbtc", symbol: "WBTC", isLpToken: false, isSwapEnabled: true },
  { id: "link", symbol: "LINK", isLpToken: false, isSwapEnabled: true },
  { id: "aave", symbol: "AAVE", isLpToken: false, isSwapEnabled: true },
  { id: "usdt", symbol: "USDT", isLpToken: false, isSwapEnabled: true },
  { id: "weth", symbol: "WETH", isLpToken: false, isSwapEnabled: true },
  // Metadata-only (dashboard / multiply collateral); not swap-routed — mirrors client catalog.
  { id: "crvusd", symbol: "crvUSD", isLpToken: false, isSwapEnabled: false },
  { id: "wsteth", symbol: "WSTETH", isLpToken: false, isSwapEnabled: false },
  { id: "eth-usdc-lp", symbol: "ETH/USDC LP", isLpToken: true, isSwapEnabled: false },
]

export function getSwapEngineAsset(assetId: string): SwapEngineAsset | undefined {
  return SWAP_ENGINE_ASSETS.find((asset) => asset.id === assetId)
}

/** A pair is routable when both legs are swap-enabled non-LP assets and differ. */
export function isSwapPairRoutable(inputAssetId: string, outputAssetId: string): boolean {
  const input = getSwapEngineAsset(inputAssetId)
  const output = getSwapEngineAsset(outputAssetId)
  return Boolean(
    input &&
    output &&
    input.id !== output.id &&
    input.isSwapEnabled &&
    output.isSwapEnabled &&
    !input.isLpToken &&
    !output.isLpToken,
  )
}

export function swapPriceImpactPct(amountUsd: number, multiplier = 1): number {
  if (amountUsd <= 100) return 0.08 * multiplier
  if (amountUsd <= 1_000) return 0.35 * multiplier
  if (amountUsd <= 10_000) return 1.5 * multiplier
  return 5 * multiplier
}

export type SwapQuoteMathInput = {
  inputAmount: number
  inputPriceUsd: number
  outputPriceUsd: number
  slippageBps: number
  feeBps?: number
  priceImpactMultiplier?: number
  networkFeeUsd?: number
}

export type SwapQuoteMath = {
  amountUsd: number
  grossOutputAmount: number
  feeAmount: number
  feeBps: number
  priceImpactPct: number
  estimatedOutputAmount: number
  minimumOutputAmount: number
  exchangeRate: number
  networkFeeUsd: number
}

/** The authoritative swap computation. Callers supply the resolved leg prices. */
export function computeSwapQuoteMath(input: SwapQuoteMathInput): SwapQuoteMath {
  const feeBps = input.feeBps ?? SWAP_FEE_BPS
  const networkFeeUsd = input.networkFeeUsd ?? SWAP_NETWORK_FEE_USD
  const amountUsd = input.inputAmount * input.inputPriceUsd
  const grossOutputAmount = input.outputPriceUsd > 0 ? amountUsd / input.outputPriceUsd : 0
  const feeAmount = grossOutputAmount * (feeBps / 10_000)
  const priceImpactPct = swapPriceImpactPct(amountUsd, input.priceImpactMultiplier ?? 1)
  const impactAmount = grossOutputAmount * (priceImpactPct / 100)
  const estimatedOutputAmount = Math.max(0, grossOutputAmount - feeAmount - impactAmount)
  const minimumOutputAmount = estimatedOutputAmount * (1 - input.slippageBps / 10_000)
  const exchangeRate = input.inputAmount > 0 ? estimatedOutputAmount / input.inputAmount : 0
  return {
    amountUsd,
    grossOutputAmount,
    feeAmount,
    feeBps,
    priceImpactPct,
    estimatedOutputAmount,
    minimumOutputAmount,
    exchangeRate,
    networkFeeUsd,
  }
}
