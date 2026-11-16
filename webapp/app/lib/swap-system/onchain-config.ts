import { createPublicClient, formatUnits, http, parseUnits, type Address } from "viem"
import { frontendFeeAmount, frontendFeeBps, frontendFeeRules } from "@/app/lib/fees/front-end-fee"
import type { FeeRules } from "@/app/lib/fees/front-end-fee"
import type { SwapAsset } from "./contracts"
import type { OnchainPoolsConfig, PoolToken, PoolVenue, QuoterClient, SwapQuoteProvider, V4PoolKey, VenueConfig } from "./providers"
import type { SwapQuote, SwapQuoteRequest } from "./quote-types"

/**
 * The on-chain swap provider's setup on a chain: the contracts Convex serves from the release
 * manifest (`deployments.swapContractsOf`), the pools tried per venue, and the Q-409 front-end fee
 * taken from the input before the route is quoted.
 */

/** `deployments.swapContractsOf` for one chain. */
export type SwapContracts = {
  chainId: number
  nativeUsdFeed: string
  venues: ReadonlyArray<{ venue: PoolVenue; router: string; quoter: string }>
  tokens: ReadonlyArray<{ symbol: string; address: string }>
  /** The chain's Lens: `PARAMETER_STORE()` gives the ParameterStore that names the fee recipient. */
  lens?: string
}

/** Uniswap v3 fee tiers tried for each hop (hundredths of a bp). */
export const V3_FEE_TIERS: readonly number[] = [100, 500, 3_000, 10_000]
/** Slipstream tick spacings tried for each hop. */
export const SLIPSTREAM_TICK_SPACINGS: readonly number[] = [1, 50, 100, 200, 2_000]
/** Hookless Uniswap v4 pools tried for each hop. */
export const V4_POOL_KEYS: readonly V4PoolKey[] = [
  { fee: 100, tickSpacing: 1 },
  { fee: 500, tickSpacing: 10 },
  { fee: 3_000, tickSpacing: 60 },
  { fee: 10_000, tickSpacing: 200 },
]
/** Assets a two-hop route may pass through. */
export const CONNECTOR_ASSET_IDS: readonly string[] = ["weth", "usdc"]

/** The swap assets the chain's manifest lists, by symbol; native ETH trades as the chain's WETH. */
export function poolTokens(contracts: SwapContracts, assets: readonly SwapAsset[]): PoolToken[] {
  const bySymbol = new Map(contracts.tokens.map((token) => [token.symbol.toUpperCase(), token.address as Address]))
  return assets.flatMap((asset) => {
    const address = bySymbol.get(asset.isNative ? "WETH" : asset.symbol.toUpperCase())
    if (!address) return []
    return [{ assetId: asset.id, symbol: asset.symbol, address, decimals: asset.decimals, ...(asset.isNative ? { isNative: true } : {}) }]
  })
}

/** Seconds a quote stays valid; an expired quote is quoted again on submit, never sent. */
export const QUOTE_VALIDITY_SECONDS = 120

/**
 * The provider config of a chain, or null when its manifest names no venue it can send a swap on.
 * Uniswap v4 is left out of route choice until v4 swaps can be sent (Permit2 and the v4 router in
 * the manifest), so a v4 route is never the one offered.
 */
export function onchainPoolsConfig(
  contracts: SwapContracts,
  assets: readonly SwapAsset[],
  extra: Pick<OnchainPoolsConfig, "networkFeeUsd" | "priceUsd"> = {},
): OnchainPoolsConfig | null {
  const venues = contracts.venues.flatMap((v): VenueConfig[] => {
    if (v.venue === "uniswap-v4") return []
    return [{ venue: v.venue, quoter: v.quoter as Address, poolKeys: v.venue === "slipstream" ? SLIPSTREAM_TICK_SPACINGS : V3_FEE_TIERS }]
  })
  if (venues.length === 0) return null
  return {
    chainId: contracts.chainId,
    tokens: poolTokens(contracts, assets),
    venues,
    connectorAssetIds: CONNECTOR_ASSET_IDS,
    quoteValiditySeconds: QUOTE_VALIDITY_SECONDS,
    ...extra,
  }
}

const CHAINLINK_ABI = [
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
] as const

/** What the provider reads from the swap chain: the quoters, the gas price and the native/USD feed (8 decimals). */
export type SwapChainClient = QuoterClient & {
  getGasPrice(): Promise<bigint>
  nativeUsd8(feed: Address): Promise<bigint>
}

/** The USD cost of `gas` units at the chain's gas price and its native/USD feed, read at most every 15 s. */
export function gasCostUsd(client: Pick<SwapChainClient, "getGasPrice" | "nativeUsd8">, nativeUsdFeed: string, clock = Date.now) {
  let cached: { at: number; read: Promise<{ gasPrice: bigint; nativeUsd8: bigint }> } | null = null
  return async (gas: bigint): Promise<number> => {
    if (!cached || clock() - cached.at > 15_000) {
      const read = Promise.all([client.getGasPrice(), client.nativeUsd8(nativeUsdFeed as Address)]).then(([gasPrice, nativeUsd8]) => ({ gasPrice, nativeUsd8 }))
      cached = { at: clock(), read }
      read.catch(() => {
        cached = null
      })
    }
    const { gasPrice, nativeUsd8 } = await cached.read
    return (Number(gas * gasPrice) / 1e18) * (Number(nativeUsd8) / 1e8)
  }
}

/** A read-only client for the Ethereum chain of this network (NEXT_PUBLIC_RPC_ETHEREUM), or null without one. */
export function swapChainClient(): SwapChainClient | null {
  const url = process.env.NEXT_PUBLIC_RPC_ETHEREUM?.trim()
  if (!url) return null
  const client = createPublicClient({ transport: http(url) })
  return {
    readContract: (args) => client.readContract(args as Parameters<typeof client.readContract>[0]),
    getGasPrice: () => client.getGasPrice(),
    nativeUsd8: async (feed) => {
      const round = await client.readContract({ address: feed, abi: CHAINLINK_ABI, functionName: "latestRoundData" })
      return round[1] > 0n ? round[1] : 0n
    },
  }
}

function toUnits(amount: number, decimals: number): bigint {
  if (!Number.isFinite(amount) || amount <= 0) return 0n
  return parseUnits(amount.toFixed(Math.min(decimals, 18)), decimals)
}

/**
 * A quote with the Q-409 front-end fee: the fee (rounded down) is taken from the input token, the
 * route is quoted on the rest, and the quote reports the fee in input-token units and its rate.
 * A provider that does not quote (CoW Swap until connected) answers as it does today.
 */
export async function quoteWithFrontendFee(
  provider: SwapQuoteProvider,
  request: SwapQuoteRequest,
  assets: readonly SwapAsset[],
  rules: FeeRules = frontendFeeRules(),
): Promise<SwapQuote> {
  const asset = assets.find((a) => a.id === request.inputAssetId)
  if (provider.id !== "onchain-pools" || !asset) return provider.quote(request)
  const units = toUnits(request.inputAmount, asset.decimals)
  const fee = frontendFeeAmount("swap", units, asset.decimals, rules)
  const quote = await provider.quote({ ...request, inputAmount: Number(formatUnits(units - fee, asset.decimals)) })
  return { ...quote, inputAmount: request.inputAmount, feeAmount: Number(formatUnits(fee, asset.decimals)), feeBps: frontendFeeBps("swap", rules) }
}
