import type { Address, Hex } from "viem"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  createOnchainPoolsProvider,
  encodePoolPath,
  resolveSwapQuoteProvider,
  swapProviderId,
  type OnchainPoolsConfig,
  type PoolToken,
  type QuoterClient,
} from "@/app/lib/swap-system/providers"

const WETH: PoolToken = {
  assetId: "weth",
  symbol: "WETH",
  address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  decimals: 18,
}
const ETH: PoolToken = { ...WETH, assetId: "eth", symbol: "ETH" }
const USDC: PoolToken = {
  assetId: "usdc",
  symbol: "USDC",
  address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  decimals: 6,
}
const LINK: PoolToken = {
  assetId: "link",
  symbol: "LINK",
  address: "0x514910771AF9Ca656af840dff83E8264EcF986CA",
  decimals: 18,
}

const config: OnchainPoolsConfig = {
  chainId: 31337,
  venue: "uniswap-v3",
  quoter: "0x61fFE014bA17989E743c5F6cB21bF9697530B21e",
  tokens: [ETH, WETH, USDC, LINK],
  poolKeys: [500, 3000],
  connectorAssetIds: ["weth", "usdc"],
  quoteValiditySeconds: 30,
  networkFeeUsd: (gas) => Number(gas) / 100_000,
}

/** Splits a packed Uniswap v3 path back into addresses and fee tiers. */
function decodePath(path: Hex): { tokens: Address[]; fees: number[] } {
  const hex = path.slice(2)
  const tokens: Address[] = []
  const fees: number[] = []
  let offset = 0
  while (offset < hex.length) {
    tokens.push(`0x${hex.slice(offset, offset + 40)}`.toLowerCase() as Address)
    offset += 40
    if (offset < hex.length) {
      fees.push(parseInt(hex.slice(offset, offset + 6), 16))
      offset += 6
    }
  }
  return { tokens, fees }
}

/**
 * A quoter with two pools: WETH/USDC at 0.05 % (2,000 USDC per WETH, 0.3 % deeper impact on a
 * full-size trade) and LINK/WETH at 0.3 % (0.01 WETH per LINK). Any other path reverts.
 */
function fakeQuoter(): QuoterClient & { calls: Hex[] } {
  const calls: Hex[] = []
  return {
    calls,
    async readContract({ args: [path, amountIn] }) {
      calls.push(path)
      const { tokens, fees } = decodePath(path)
      const key = tokens.map((token, index) => (index < fees.length ? `${token}:${fees[index]}` : token)).join(">")
      const weth = WETH.address.toLowerCase()
      const usdc = USDC.address.toLowerCase()
      const link = LINK.address.toLowerCase()
      const full = amountIn >= 10n ** 17n
      if (key === `${weth}:500>${usdc}`) {
        const out = (amountIn * 2000n * 10n ** 6n) / 10n ** 18n
        return [full ? (out * 997n) / 1000n : out, [], [], 120_000n] as const
      }
      if (key === `${link}:3000>${weth}:500>${usdc}`) {
        return [(amountIn * 20n * 10n ** 6n) / 10n ** 18n, [], [], 200_000n] as const
      }
      throw new Error("execution reverted")
    },
  }
}

describe("encodePoolPath", () => {
  it("packs token, 3-byte fee tier, token", () => {
    const path = encodePoolPath({ tokens: [WETH, USDC], poolKeys: [500] }, "uniswap-v3")
    expect(path.length).toBe(2 + (20 + 3 + 20) * 2)
    expect(decodePath(path)).toEqual({ tokens: [WETH.address.toLowerCase(), USDC.address.toLowerCase()], fees: [500] })
  })

  it("packs Slipstream tick spacings in the same 3 bytes", () => {
    const path = encodePoolPath({ tokens: [WETH, USDC], poolKeys: [100] }, "slipstream")
    expect(decodePath(path).fees).toEqual([100])
  })
})

describe("on-chain pools provider", () => {
  const clock = () => 1_000_000

  it("quotes the direct pool with output, minimum, fee, impact, network fee and expiry", async () => {
    const provider = createOnchainPoolsProvider(config, fakeQuoter(), undefined, clock)
    const quote = await provider.quote({
      walletId: "0xabc",
      chainId: 31337,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 1,
      slippageBps: 50,
    })
    expect(quote.status).toBe("valid")
    expect(quote.provider).toBe("Uniswap v3")
    expect(quote.route).toEqual(["ETH", "USDC"])
    expect(quote.estimatedOutputAmount).toBeCloseTo(1994)
    expect(quote.minimumOutputAmount).toBeCloseTo(1994 * 0.995)
    expect(quote.exchangeRate).toBeCloseTo(1994)
    expect(quote.feeBps).toBe(5)
    expect(quote.priceImpactPct).toBeCloseTo(0.3)
    expect(quote.networkFeeUsd).toBeCloseTo(1.2)
    expect(quote.expiresAt).toBe(1_000_000 + 30_000)
  })

  it("routes through a connector token when there is no direct pool", async () => {
    const provider = createOnchainPoolsProvider(config, fakeQuoter(), undefined, clock)
    const quote = await provider.quote({
      walletId: "0xabc",
      chainId: 31337,
      inputAssetId: "link",
      outputAssetId: "usdc",
      inputAmount: 10,
      slippageBps: 50,
    })
    expect(quote.status).toBe("valid")
    expect(quote.route).toEqual(["LINK", "WETH", "USDC"])
    expect(quote.estimatedOutputAmount).toBeCloseTo(200)
    // 1 − 0.997 × 0.9995 of the input stays in the two pools.
    expect(quote.feeBps).toBeCloseTo(34.98, 2)
  })

  it("answers unsupported for an unknown token, another chain or no route", async () => {
    const provider = createOnchainPoolsProvider(config, fakeQuoter(), undefined, clock)
    const base = { walletId: "0xabc", chainId: 31337, inputAmount: 1, slippageBps: 50 }
    expect((await provider.quote({ ...base, inputAssetId: "doge", outputAssetId: "usdc" })).status).toBe("unsupported")
    expect((await provider.quote({ ...base, chainId: 1, inputAssetId: "eth", outputAssetId: "usdc" })).status).toBe(
      "unsupported",
    )
    expect((await provider.quote({ ...base, inputAssetId: "usdc", outputAssetId: "link" })).status).toBe("unsupported")
    expect((await provider.quote({ ...base, inputAssetId: "eth", outputAssetId: "weth" })).status).toBe("unsupported")
  })

  it("quotes nothing for a zero amount", async () => {
    const quoter = fakeQuoter()
    const provider = createOnchainPoolsProvider(config, quoter, undefined, clock)
    const quote = await provider.quote({
      walletId: "0xabc",
      chainId: 31337,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 0,
      slippageBps: 50,
    })
    expect(quote.status).toBe("idle")
    expect(quoter.calls).toHaveLength(0)
  })
})

describe("provider selection", () => {
  afterEach(() => {
    vi.unstubAllEnvs()
  })

  it("defaults to CoW Swap, which answers unsupported until connected", async () => {
    expect(swapProviderId()).toBe("cow-swap")
    const provider = resolveSwapQuoteProvider({ config, client: fakeQuoter() })
    expect(provider.id).toBe("cow-swap")
    const quote = await provider.quote({
      walletId: "0xabc",
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 1,
      slippageBps: 50,
    })
    expect(quote.status).toBe("unsupported")
    expect(quote.provider).toBe("CoW Swap")
  })

  it("uses the chain's pools when NEXT_PUBLIC_AVANA_SWAP_PROVIDER is onchain-pools", () => {
    vi.stubEnv("NEXT_PUBLIC_AVANA_SWAP_PROVIDER", "onchain-pools")
    expect(resolveSwapQuoteProvider({ config, client: fakeQuoter() }).id).toBe("onchain-pools")
    // Without a pool config for the chain it keeps CoW Swap.
    expect(resolveSwapQuoteProvider(null).id).toBe("cow-swap")
  })
})
