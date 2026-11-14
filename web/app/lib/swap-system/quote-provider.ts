import { getSwapAsset, getSwapPair } from "./catalog"
import type { SwapRestrictionReason } from "./contracts"
import {
  SWAP_NETWORK_FEE_USD,
  SWAP_PROVIDER,
  SWAP_QUOTE_TTL_MS,
  computeSwapQuoteMath,
} from "@/convex/sandbox/swapQuoteEngine"

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

export type SwapProvider = {
  getQuote(request: SwapQuoteRequest): Promise<SwapQuote>
}

type MockSwapProviderOptions = {
  now?: () => number
  quoteTtlMs?: number
  networkFeeUsd?: number
  priceImpactMultiplier?: number
}

// The quote TTL must outlast the multi-step review, or it expires mid-read and flickers the
// amount; 2 minutes covers review + confirmation. Submit still auto-refreshes a stale quote.
function quoteId(request: SwapQuoteRequest, createdAt: number) {
  return `quote-${request.walletId}-${request.inputAssetId}-${request.outputAssetId}-${request.inputAmount}-${request.slippageBps}-${createdAt}`
}

export function getQuoteStatus(quote: SwapQuote, now = Date.now()) {
  if (quote.status !== "valid" && quote.status !== "stale") return quote.status
  return now >= quote.expiresAt ? "expired" : quote.status
}

export function isQuoteUsable(quote: SwapQuote, now = Date.now()) {
  return getQuoteStatus(quote, now) === "valid"
}

export class MockSwapProvider implements SwapProvider {
  private readonly now: () => number
  private readonly quoteTtlMs: number
  private readonly networkFeeUsd: number
  private readonly priceImpactMultiplier: number

  constructor(options: MockSwapProviderOptions = {}) {
    this.now = options.now ?? Date.now
    this.quoteTtlMs = options.quoteTtlMs ?? SWAP_QUOTE_TTL_MS
    this.networkFeeUsd = options.networkFeeUsd ?? SWAP_NETWORK_FEE_USD
    this.priceImpactMultiplier = options.priceImpactMultiplier ?? 1
  }

  async getQuote(request: SwapQuoteRequest): Promise<SwapQuote> {
    const createdAt = request.requestedAt ?? this.now()
    const pair = getSwapPair(request.inputAssetId, request.outputAssetId, request.chainId)
    const inputAsset = getSwapAsset(request.inputAssetId)
    const outputAsset = getSwapAsset(request.outputAssetId)

    if (!inputAsset || !outputAsset || !pair?.isEnabled || inputAsset.isLpToken || outputAsset.isLpToken) {
      return {
        id: quoteId(request, createdAt),
        status: "unsupported",
        provider: pair?.provider ?? SWAP_PROVIDER,
        chainId: request.chainId,
        inputAssetId: request.inputAssetId,
        outputAssetId: request.outputAssetId,
        inputAmount: request.inputAmount,
        estimatedOutputAmount: 0,
        minimumOutputAmount: 0,
        exchangeRate: 0,
        feeAmount: 0,
        feeBps: pair?.feeBps ?? 0,
        priceImpactPct: 0,
        slippageBps: request.slippageBps,
        networkFeeUsd: this.networkFeeUsd,
        expiresAt: createdAt,
        createdAt,
        route: [],
        rejectionReason: inputAsset?.isLpToken || outputAsset?.isLpToken ? "ineligible_lp_token" : "unsupported_pair",
      }
    }

    const math = computeSwapQuoteMath({
      inputAmount: request.inputAmount,
      inputPriceUsd: inputAsset.priceUsd,
      outputPriceUsd: outputAsset.priceUsd,
      slippageBps: request.slippageBps,
      feeBps: pair.feeBps,
      networkFeeUsd: this.networkFeeUsd,
      priceImpactMultiplier: this.priceImpactMultiplier,
    })

    return {
      id: quoteId(request, createdAt),
      status: "valid",
      provider: pair.provider,
      chainId: request.chainId,
      inputAssetId: request.inputAssetId,
      outputAssetId: request.outputAssetId,
      inputAmount: request.inputAmount,
      estimatedOutputAmount: math.estimatedOutputAmount,
      minimumOutputAmount: math.minimumOutputAmount,
      exchangeRate: math.exchangeRate,
      feeAmount: math.feeAmount,
      feeBps: math.feeBps,
      priceImpactPct: math.priceImpactPct,
      slippageBps: request.slippageBps,
      networkFeeUsd: math.networkFeeUsd,
      expiresAt: createdAt + this.quoteTtlMs,
      createdAt,
      route: [inputAsset.symbol, outputAsset.symbol],
    }
  }
}
