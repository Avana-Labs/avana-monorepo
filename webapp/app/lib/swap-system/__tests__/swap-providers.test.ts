import { zeroAddress, type Address, type Hex } from "viem"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  createOnchainPoolsProvider,
  encodePoolPath,
  resolveSwapQuoteProvider,
  swapProviderId,
  v4QuoteParams,
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
const ETH: PoolToken = { ...WETH, assetId: "eth", symbol: "ETH", isNative: true }
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

const V3_QUOTER: Address = "0x61fFE014bA17989E743c5F6cB21bF9697530B21e"
const V4_QUOTER: Address = "0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203"

const v3Only: OnchainPoolsConfig = {
  chainId: 31337,
  tokens: [ETH, WETH, USDC, LINK],
  venues: [{ venue: "uniswap-v3", quoter: V3_QUOTER, poolKeys: [500, 3000] }],
  connectorAssetIds: ["weth", "usdc"],
  quoteValiditySeconds: 30,
  networkFeeUsd: (gas) => Number(gas) / 100_000,
}

const withV4: OnchainPoolsConfig = {
  ...v3Only,
  venues: [
    ...v3Only.venues,
    {
      venue: "uniswap-v4",
      quoter: V4_QUOTER,
      poolKeys: [
        { fee: 500, tickSpacing: 10 },
        { fee: 3000, tickSpacing: 60 },
      ],
    },
  ],
  priceUsd: (assetId) => (assetId === "usdc" ? 1 : undefined),
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

type V4Params = ReturnType<typeof v4QuoteParams>

/**
 * A chain with:
 * - Uniswap v3 WETH/USDC 0.05 %: 2,000 USDC per WETH, 0.3 % less on a full-size trade, 120k gas.
 * - Uniswap v3 LINK/WETH 0.3 %: 0.01 WETH per LINK (so 20 USDC per LINK through WETH), 200k gas.
 * - Uniswap v4 ETH/USDC 0.05 % (native ETH), when `v4Rate` is set: v4Rate USDC per ETH, `v4Gas` gas.
 * Any other route reverts.
 */
function fakeChain(v4Rate?: bigint, v4Gas = 100_000n): QuoterClient & { v4Calls: V4Params[] } {
  const v4Calls: V4Params[] = []
  const weth = WETH.address.toLowerCase()
  const usdc = USDC.address.toLowerCase()
  const link = LINK.address.toLowerCase()
  return {
    v4Calls,
    async readContract({ address, args }) {
      if (address === V4_QUOTER) {
        const params = args[0] as V4Params
        v4Calls.push(params)
        const hop = params.path[0]
        if (
          v4Rate !== undefined &&
          params.exactCurrency === zeroAddress &&
          params.path.length === 1 &&
          hop?.intermediateCurrency === USDC.address &&
          hop.fee === 500 &&
          hop.tickSpacing === 10 &&
          hop.hooks === zeroAddress
        ) {
          return [(params.exactAmount * v4Rate * 10n ** 6n) / 10n ** 18n, v4Gas] as const
        }
        throw new Error("execution reverted")
      }
      const [path, amountIn] = args as [Hex, bigint]
      const { tokens, fees } = decodePath(path)
      const key = tokens.map((token, index) => (index < fees.length ? `${token}:${fees[index]}` : token)).join(">")
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

const request = { walletId: "0xabc", chainId: 31337, slippageBps: 50 }
const clock = () => 1_000_000

describe("pool paths", () => {
  it("packs token, 3-byte fee tier, token for Uniswap v3", () => {
    const path = encodePoolPath({ tokens: [WETH, USDC], poolKeys: [500] }, "uniswap-v3")
    expect(path.length).toBe(2 + (20 + 3 + 20) * 2)
    expect(decodePath(path)).toEqual({ tokens: [WETH.address.toLowerCase(), USDC.address.toLowerCase()], fees: [500] })
  })

  it("packs Slipstream tick spacings in the same 3 bytes", () => {
    expect(decodePath(encodePoolPath({ tokens: [WETH, USDC], poolKeys: [100] }, "slipstream")).fees).toEqual([100])
  })

  it("builds Uniswap v4 path keys over hookless pools, with native ETH as address(0)", () => {
    const params = v4QuoteParams(
      {
        tokens: [ETH, WETH, USDC],
        poolKeys: [
          { fee: 100, tickSpacing: 1 },
          { fee: 500, tickSpacing: 10 },
        ],
      },
      7n,
    )
    expect(params.exactCurrency).toBe(zeroAddress)
    expect(params.exactAmount).toBe(7n)
    expect(params.path).toEqual([
      { intermediateCurrency: WETH.address, fee: 100, tickSpacing: 1, hooks: zeroAddress, hookData: "0x" },
      { intermediateCurrency: USDC.address, fee: 500, tickSpacing: 10, hooks: zeroAddress, hookData: "0x" },
    ])
  })
})

describe("on-chain pools provider", () => {
  it("quotes the direct pool with output, minimum, fee, impact, network fee and expiry", async () => {
    const provider = createOnchainPoolsProvider(v3Only, fakeChain(), clock)
    const quote = await provider.quote({ ...request, inputAssetId: "eth", outputAssetId: "usdc", inputAmount: 1 })
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
    const provider = createOnchainPoolsProvider(v3Only, fakeChain(), clock)
    const quote = await provider.quote({ ...request, inputAssetId: "link", outputAssetId: "usdc", inputAmount: 10 })
    expect(quote.status).toBe("valid")
    expect(quote.route).toEqual(["LINK", "WETH", "USDC"])
    expect(quote.estimatedOutputAmount).toBeCloseTo(200)
    // 1 − 0.997 × 0.9995 of the input stays in the two pools.
    expect(quote.feeBps).toBeCloseTo(34.98, 2)
  })

  it("takes the Uniswap v4 pool when it gives more net of gas, and names the venue", async () => {
    const chain = fakeChain(2000n)
    const provider = createOnchainPoolsProvider(withV4, chain, clock)
    const quote = await provider.quote({ ...request, inputAssetId: "eth", outputAssetId: "usdc", inputAmount: 1 })
    expect(quote.provider).toBe("Uniswap v4")
    expect(quote.route).toEqual(["ETH", "USDC"])
    expect(quote.estimatedOutputAmount).toBeCloseTo(2000)
    expect(quote.networkFeeUsd).toBeCloseTo(1)
    expect(chain.v4Calls.length).toBeGreaterThan(0)
    // A v4 route can be shown by the provider but is never kept as a route to send.
    expect(provider.executionRoute?.(quote.id)).toBeUndefined()
  })

  it("keeps the route of a v3 quote to send it as priced", async () => {
    const provider = createOnchainPoolsProvider(v3Only, fakeChain(), clock)
    const quote = await provider.quote({ ...request, inputAssetId: "eth", outputAssetId: "usdc", inputAmount: 1 })
    const route = provider.executionRoute?.(quote.id)
    expect(route).toMatchObject({ venue: "uniswap-v3", amountIn: 10n ** 18n })
    expect(route!.route.tokens.map((t) => t.symbol)).toEqual(["ETH", "USDC"])
    expect(route!.amountOut).toBeGreaterThan(0n)
  })

  it("keeps Uniswap v3 when the v4 output is higher but its gas eats the difference", async () => {
    // v4 gives 1,995 USDC for 50 USD of gas; v3 gives 1,994 for 1.2 USD.
    const provider = createOnchainPoolsProvider(withV4, fakeChain(1995n, 5_000_000n), clock)
    const quote = await provider.quote({ ...request, inputAssetId: "eth", outputAssetId: "usdc", inputAmount: 1 })
    expect(quote.provider).toBe("Uniswap v3")
    expect(quote.estimatedOutputAmount).toBeCloseTo(1994)
  })

  it("does not quote a token against itself (ETH and WETH on v3, ETH and ETH on v4)", async () => {
    const provider = createOnchainPoolsProvider(withV4, fakeChain(2000n), clock)
    const quote = await provider.quote({ ...request, inputAssetId: "eth", outputAssetId: "weth", inputAmount: 1 })
    expect(quote.status).toBe("unsupported")
  })

  it("answers unsupported for an unknown token, another chain or no route", async () => {
    const provider = createOnchainPoolsProvider(v3Only, fakeChain(), clock)
    const base = { ...request, inputAmount: 1 }
    expect((await provider.quote({ ...base, inputAssetId: "doge", outputAssetId: "usdc" })).status).toBe("unsupported")
    expect((await provider.quote({ ...base, chainId: 1, inputAssetId: "eth", outputAssetId: "usdc" })).status).toBe(
      "unsupported",
    )
    expect((await provider.quote({ ...base, inputAssetId: "usdc", outputAssetId: "link" })).status).toBe("unsupported")
  })

  it("quotes nothing for a zero amount", async () => {
    const chain = fakeChain(2000n)
    const provider = createOnchainPoolsProvider(withV4, chain, clock)
    const quote = await provider.quote({ ...request, inputAssetId: "eth", outputAssetId: "usdc", inputAmount: 0 })
    expect(quote.status).toBe("idle")
    expect(chain.v4Calls).toHaveLength(0)
  })
})

describe("provider selection", () => {
  afterEach(() => {
    vi.unstubAllEnvs()
  })

  it("defaults to CoW Swap, which answers unsupported until connected", async () => {
    expect(swapProviderId()).toBe("cow-swap")
    const provider = resolveSwapQuoteProvider({ config: v3Only, client: fakeChain() })
    expect(provider.id).toBe("cow-swap")
    const quote = await provider.quote({
      ...request,
      chainId: 1,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 1,
    })
    expect(quote.status).toBe("unsupported")
    expect(quote.provider).toBe("CoW Swap")
  })

  it("uses the chain's pools when NEXT_PUBLIC_AVANA_SWAP_PROVIDER is onchain-pools", () => {
    vi.stubEnv("NEXT_PUBLIC_AVANA_SWAP_PROVIDER", "onchain-pools")
    expect(resolveSwapQuoteProvider({ config: withV4, client: fakeChain() }).id).toBe("onchain-pools")
    // Without a pool config for the chain it keeps CoW Swap.
    expect(resolveSwapQuoteProvider(null).id).toBe("cow-swap")
  })
})
