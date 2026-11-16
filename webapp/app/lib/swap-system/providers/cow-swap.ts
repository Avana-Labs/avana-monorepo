import { unsupportedSwapQuote } from "../quote-types"
import type { SwapQuoteProvider } from "./types"

/** CoW Swap. Not connected yet: every quote is answered "unsupported", as before. */
export const cowSwapProvider: SwapQuoteProvider = {
  id: "cow-swap",
  name: "CoW Swap",
  quote: async (request) => unsupportedSwapQuote(request),
}
