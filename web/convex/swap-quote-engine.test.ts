import { describe, expect, it } from "vitest"
import { MockSwapProvider } from "@/app/lib/swap-system/quote-provider"
import { SWAP_ASSETS, getSwapAsset } from "@/app/lib/swap-system/catalog"
import { SWAP_ENGINE_ASSETS, computeSwapQuoteMath } from "@/convex/sandbox/swapQuoteEngine"

describe("shared swap quote engine", () => {
  it("matches the client MockSwapProvider math for the same inputs (one engine, no drift)", async () => {
    const provider = new MockSwapProvider({ now: () => 1000 })
    const request = {
      walletId: "w",
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 2,
      slippageBps: 50,
      requestedAt: 1000,
    }
    const quote = await provider.getQuote(request)
    const input = getSwapAsset("eth")!
    const output = getSwapAsset("usdc")!
    const math = computeSwapQuoteMath({
      inputAmount: 2,
      inputPriceUsd: input.priceUsd,
      outputPriceUsd: output.priceUsd,
      slippageBps: 50,
    })
    expect(math.estimatedOutputAmount).toBeCloseTo(quote.estimatedOutputAmount, 9)
    expect(math.minimumOutputAmount).toBeCloseTo(quote.minimumOutputAmount, 9)
    expect(math.exchangeRate).toBeCloseTo(quote.exchangeRate, 9)
    expect(math.feeAmount).toBeCloseTo(quote.feeAmount, 9)
    expect(math.priceImpactPct).toBeCloseTo(quote.priceImpactPct, 9)
    expect(math.feeBps).toBe(quote.feeBps)
    expect(math.networkFeeUsd).toBeCloseTo(quote.networkFeeUsd, 9)
  })

  it("server engine asset registry stays in parity with the client swap catalog", () => {
    // Same asset set (id, symbol, isLpToken, swappability) so the server can't route or reject
    // a pair differently than the client catalog would.
    expect(SWAP_ENGINE_ASSETS.length).toBe(SWAP_ASSETS.length)
    for (const asset of SWAP_ASSETS) {
      const engine = SWAP_ENGINE_ASSETS.find((entry) => entry.id === asset.id)
      expect(engine, `engine asset for ${asset.id}`).toBeDefined()
      expect(engine!.symbol).toBe(asset.symbol)
      expect(engine!.isLpToken).toBe(asset.isLpToken)
      expect(engine!.isSwapEnabled).toBe(asset.isSwapEnabled)
    }
  })
})
