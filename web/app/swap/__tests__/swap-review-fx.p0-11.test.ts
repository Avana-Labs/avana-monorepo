import { describe, expect, it } from "vitest"
import { MockSwapProvider } from "@/app/lib/swap-system/quote-provider"
import { SWAP_ASSETS } from "@/app/lib/swap-system/catalog"

describe("swap review FX consistency", () => {
  it("p0-11: quoted output is below the gross sell notional after fees and impact", async () => {
    const quote = await new MockSwapProvider({ now: () => 1 }).getQuote({
      walletId: "w",
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 0.01,
      slippageBps: 50,
    })
    const eth = SWAP_ASSETS.find((asset) => asset.id === "eth")!
    const usdc = SWAP_ASSETS.find((asset) => asset.id === "usdc")!
    const grossSellUsd = 0.01 * eth.priceUsd
    const quotedOutputUsd = quote.estimatedOutputAmount * usdc.priceUsd
    expect(quote.status).toBe("valid")
    expect(quotedOutputUsd).toBeCloseTo(quote.exchangeRate * 0.01 * usdc.priceUsd, 6)
    expect(quotedOutputUsd).toBeLessThan(grossSellUsd)
  })
})
