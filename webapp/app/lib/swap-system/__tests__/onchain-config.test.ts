import { describe, expect, it, vi } from "vitest"
import { DEFAULT_FEE_RULES } from "@/convex/lib/fees"
import { SWAP_ASSETS } from "@/app/lib/swap-system/catalog"
import {
  CONNECTOR_ASSET_IDS,
  SLIPSTREAM_TICK_SPACINGS,
  V3_FEE_TIERS,
  V4_POOL_KEYS,
  gasCostUsd,
  onchainPoolsConfig,
  poolTokens,
  quoteWithFrontendFee,
  type SwapContracts,
} from "@/app/lib/swap-system/onchain-config"
import { unsupportedSwapQuote, type SwapQuote, type SwapQuoteRequest } from "@/app/lib/swap-system/quote-types"
import type { SwapQuoteProvider } from "@/app/lib/swap-system/providers"

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}`
const contracts: SwapContracts = {
  chainId: 31337,
  nativeUsdFeed: A(9),
  venues: [
    { venue: "uniswap-v3", router: A(1), quoter: A(2) },
    { venue: "uniswap-v4", router: A(3), quoter: A(4) },
  ],
  tokens: [
    { symbol: "USDC", address: A(10) },
    { symbol: "WETH", address: A(11) },
    { symbol: "AERO", address: A(12) },
  ],
}

describe("on-chain swap config", () => {
  it("lists the catalog assets the manifest names, native ETH as WETH", () => {
    const tokens = poolTokens(contracts, SWAP_ASSETS)
    expect(tokens.map((t) => [t.assetId, t.address, t.isNative ?? false])).toEqual([
      ["eth", A(11), true],
      ["usdc", A(10), false],
      ["weth", A(11), false],
    ])
  })

  it("tries the agreed pools per venue and routes through WETH and USDC", () => {
    const config = onchainPoolsConfig(contracts, SWAP_ASSETS)!
    expect(config.venues).toEqual([
      { venue: "uniswap-v3", quoter: A(2), poolKeys: V3_FEE_TIERS },
      { venue: "uniswap-v4", quoter: A(4), poolKeys: V4_POOL_KEYS },
    ])
    expect(config.connectorAssetIds).toEqual(CONNECTOR_ASSET_IDS)
    expect(onchainPoolsConfig({ ...contracts, venues: [{ venue: "slipstream", router: A(5), quoter: A(6) }] }, SWAP_ASSETS)!.venues[0]!.poolKeys).toEqual(
      SLIPSTREAM_TICK_SPACINGS,
    )
    expect(onchainPoolsConfig({ ...contracts, venues: [] }, SWAP_ASSETS)).toBeNull()
  })

  it("values gas at the chain's gas price and native/USD feed", async () => {
    const client = { getGasPrice: vi.fn(async () => 2_000_000_000n), nativeUsd8: vi.fn(async () => 3_000n * 10n ** 8n) }
    const cost = gasCostUsd(client, A(9), () => 0)
    // 150,000 gas × 2 gwei = 0.0003 ETH at $3,000.
    expect(await cost(150_000n)).toBeCloseTo(0.9, 10)
    await cost(1n)
    expect(client.getGasPrice).toHaveBeenCalledTimes(1)
  })
})

describe("swap quotes with the front-end fee", () => {
  const request: SwapQuoteRequest = { walletId: "w", chainId: 31337, inputAssetId: "usdc", outputAssetId: "weth", inputAmount: 1_000, slippageBps: 50 }

  it("takes 10 bps of the input first and quotes the route on the rest", async () => {
    const seen: number[] = []
    const provider: SwapQuoteProvider = {
      id: "onchain-pools",
      name: "Uniswap v3",
      quote: async (r): Promise<SwapQuote> => {
        seen.push(r.inputAmount)
        return { ...unsupportedSwapQuote(r), status: "valid", estimatedOutputAmount: 0.333, feeAmount: 0.3, feeBps: 30 }
      },
    }
    const quote = await quoteWithFrontendFee(provider, request, SWAP_ASSETS, DEFAULT_FEE_RULES)
    expect(seen).toEqual([999])
    expect(quote).toMatchObject({ inputAmount: 1_000, feeAmount: 1, feeBps: 10, estimatedOutputAmount: 0.333 })
  })

  it("rounds the fee down in the input token's units", async () => {
    const provider: SwapQuoteProvider = { id: "onchain-pools", name: "x", quote: async (r) => unsupportedSwapQuote(r) }
    // 0.000019 USDC (19 units) × 10 bps = 0.019 units, rounded down to 0.
    expect((await quoteWithFrontendFee(provider, { ...request, inputAmount: 0.000019 }, SWAP_ASSETS, DEFAULT_FEE_RULES)).feeAmount).toBe(0)
  })

  it("leaves a provider that does not quote as it answers today", async () => {
    const provider: SwapQuoteProvider = { id: "cow-swap", name: "CoW Swap", quote: async (r) => unsupportedSwapQuote(r) }
    const quote = await quoteWithFrontendFee(provider, request, SWAP_ASSETS, DEFAULT_FEE_RULES)
    expect(quote).toMatchObject({ status: "unsupported", inputAmount: 1_000, feeAmount: 0, feeBps: 0 })
  })
})
