import { describe, expect, it } from "vitest"
import { MockSwapProvider, getQuoteStatus, isQuoteUsable } from "@/app/lib/swap-system"

describe("MockSwapProvider", () => {
  it("calculates output, fee, slippage minimum, and expiry deterministically", async () => {
    const provider = new MockSwapProvider({ now: () => 1_000, quoteTtlMs: 20_000, networkFeeUsd: 0.25 })

    const quote = await provider.getQuote({
      walletId: "demo-wallet",
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 1,
      slippageBps: 50,
    })

    expect(quote.status).toBe("valid")
    expect(quote.feeBps).toBe(30)
    expect(quote.feeAmount).toBeCloseTo(5.802)
    expect(quote.estimatedOutputAmount).toBeCloseTo(1899.187)
    expect(quote.minimumOutputAmount).toBeCloseTo(1889.691065)
    expect(quote.expiresAt).toBe(21_000)
    expect(quote.networkFeeUsd).toBe(0.25)
  })

  it("rejects unsupported and LP-token pairs", async () => {
    const provider = new MockSwapProvider({ now: () => 1_000 })

    await expect(
      provider.getQuote({
        walletId: "demo-wallet",
        chainId: 1,
        inputAssetId: "eth-usdc-lp",
        outputAssetId: "usdc",
        inputAmount: 1,
        slippageBps: 50,
      }),
    ).resolves.toMatchObject({
      status: "unsupported",
      rejectionReason: "ineligible_lp_token",
    })

    await expect(
      provider.getQuote({
        walletId: "demo-wallet",
        chainId: 1,
        inputAssetId: "eth",
        outputAssetId: "not-real",
        inputAmount: 1,
        slippageBps: 50,
      }),
    ).resolves.toMatchObject({
      status: "unsupported",
      rejectionReason: "unsupported_pair",
    })
  })

  it("marks expired and stale quotes unusable", async () => {
    const provider = new MockSwapProvider({ now: () => 1_000, quoteTtlMs: 20_000 })
    const quote = await provider.getQuote({
      walletId: "demo-wallet",
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 1,
      slippageBps: 50,
    })

    expect(isQuoteUsable(quote, 20_999)).toBe(true)
    expect(getQuoteStatus(quote, 21_000)).toBe("expired")
    expect(isQuoteUsable(quote, 21_000)).toBe(false)

    const stale = { ...quote, status: "stale" as const }
    expect(isQuoteUsable(stale, 2_000)).toBe(false)
  })

  it("returns a new quote when the pair is reversed", async () => {
    const provider = new MockSwapProvider({ now: () => 1_000 })
    const ethToUsdc = await provider.getQuote({
      walletId: "demo-wallet",
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 1,
      slippageBps: 50,
    })
    const usdcToEth = await provider.getQuote({
      walletId: "demo-wallet",
      chainId: 1,
      inputAssetId: "usdc",
      outputAssetId: "eth",
      inputAmount: 1934,
      slippageBps: 50,
    })

    expect(ethToUsdc.id).not.toBe(usdcToEth.id)
    expect(ethToUsdc.route).toEqual(["ETH", "USDC"])
    expect(usdcToEth.route).toEqual(["USDC", "ETH"])
  })
})
