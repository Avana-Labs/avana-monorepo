import { describe, expect, it } from "vitest"
import { SWAP_PAIRS } from "@/app/lib/swap-system/catalog"
import { MockSwapProvider } from "@/app/lib/swap-system/quote-provider"

describe("swap sandbox honesty", () => {
  it("p0-07: every catalog pair is labeled Avana mock router", async () => {
    expect(SWAP_PAIRS.every((pair) => pair.provider === "Avana mock router")).toBe(true)
    const quote = await new MockSwapProvider({ now: () => 1 }).getQuote({
      walletId: "w",
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 1,
      slippageBps: 50,
    })
    expect(quote.provider).toBe("Avana mock router")
  })
})
