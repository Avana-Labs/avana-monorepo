import type { SwapRestrictionReason, UserAssetBalance } from "./contracts"

// Quote and transaction shapes of the Swap UI. Quotes will come from CoW Swap; until that
// integration lands every quote is answered "unsupported" and no swap runs.

export type SwapQuoteStatus = "idle" | "loading" | "valid" | "stale" | "expired" | "unsupported" | "error"

export type SwapQuoteRequest = {
  walletId: string
  chainId: number
  inputAssetId: string
  outputAssetId: string
  inputAmount: number
  slippageBps: number
  requestedAt?: number
}

export type SwapQuote = {
  id: string
  status: SwapQuoteStatus
  provider: string
  chainId: number
  inputAssetId: string
  outputAssetId: string
  inputAmount: number
  estimatedOutputAmount: number
  minimumOutputAmount: number
  exchangeRate: number
  feeAmount: number
  feeBps: number
  priceImpactPct: number
  slippageBps: number
  networkFeeUsd: number
  expiresAt: number
  createdAt: number
  route: string[]
  rejectionReason?: SwapRestrictionReason
}

export function getQuoteStatus(quote: SwapQuote, now = Date.now()) {
  if (quote.status !== "valid" && quote.status !== "stale") return quote.status
  return now >= quote.expiresAt ? "expired" : quote.status
}

export function isQuoteUsable(quote: SwapQuote, now = Date.now()) {
  return getQuoteStatus(quote, now) === "valid"
}

/** The quote shown until the CoW Swap integration lands: no route, no amounts. */
export function unsupportedSwapQuote(request: SwapQuoteRequest, now = Date.now()): SwapQuote {
  return {
    id: `quote-${request.inputAssetId}-${request.outputAssetId}-${now}`,
    status: "unsupported",
    provider: "CoW Swap",
    chainId: request.chainId,
    inputAssetId: request.inputAssetId,
    outputAssetId: request.outputAssetId,
    inputAmount: request.inputAmount,
    estimatedOutputAmount: 0,
    minimumOutputAmount: 0,
    exchangeRate: 0,
    feeAmount: 0,
    feeBps: 0,
    priceImpactPct: 0,
    slippageBps: request.slippageBps,
    networkFeeUsd: 0,
    expiresAt: now,
    createdAt: now,
    route: [],
    rejectionReason: "unsupported_pair",
  }
}

export type SwapTransactionStatus =
  "approval_pending" | "approval_confirmed" | "swap_pending" | "confirmed" | "failed" | "rejected" | "expired"

export type SwapTransactionRecord = {
  id: string
  walletId: string
  inputAssetId: string
  outputAssetId: string
  inputAmount: number
  outputAmount: number
  minimumOutputAmount: number
  quoteId: string
  provider: string
  exchangeRate: number
  priceImpactPct: number
  slippageBps: number
  networkFeeUsd: number
  route: string[]
  approvalTransactionHash?: string
  swapTransactionHash?: string
  status: SwapTransactionStatus
  failureReason?: string
  createdAt: number
  confirmedAt?: number
}

export type SwapSystemState = {
  balances: UserAssetBalance[]
  allowances: Record<string, number>
  transactions: SwapTransactionRecord[]
}

export type SwapExecutionOptions = {
  rejectApproval?: boolean
  failApproval?: boolean
  rejectSwap?: boolean
  revertSwap?: boolean
  now?: number
}
