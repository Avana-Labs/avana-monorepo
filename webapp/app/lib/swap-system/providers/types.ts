import type { SwapQuote, SwapQuoteRequest } from "../quote-types"
import type { ExecutionRoute } from "./onchain-pools"

/**
 * Where swap quotes come from. CoW Swap on the public networks; on a network CoW Swap does not
 * serve (the local chains), the chain's own Uniswap v3, Uniswap v4 or Aero Slipstream pools. The Swap UI
 * reads every provider through this one interface.
 */
export type SwapProviderId = "cow-swap" | "onchain-pools"

export type SwapQuoteProvider = {
  readonly id: SwapProviderId
  /** Shown as the quote's provider. */
  readonly name: string
  quote(request: SwapQuoteRequest): Promise<SwapQuote>
  /** The route a valid quote was priced on, kept so that exact route is the one sent (on-chain pools only). */
  executionRoute?(quoteId: string): ExecutionRoute | undefined
}
