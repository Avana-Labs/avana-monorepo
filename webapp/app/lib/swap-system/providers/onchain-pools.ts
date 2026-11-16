import { encodePacked, formatUnits, parseUnits, zeroAddress, type Address, type Hex } from "viem"
import type { SwapQuote, SwapQuoteRequest } from "../quote-types"
import type { SwapQuoteProvider } from "./types"

/**
 * Quotes from a chain's own pools: Uniswap v3 and Uniswap v4 on Ethereum, Aero Slipstream on
 * Base. For each venue it tries the direct pools and the one-hop routes through the configured
 * connector tokens, and it keeps the route with the best output net of its gas cost.
 *
 * - Uniswap v3 and Slipstream: QuoterV2 `quoteExactInput(path, amountIn)`; the packed path carries
 *   the fee tier (v3) or the tick spacing (Slipstream) between tokens. Native ETH trades as WETH.
 * - Uniswap v4: V4Quoter `quoteExactInput((exactCurrency, PathKey[], exactAmount))` over hookless
 *   pools keyed by (fee, tick spacing); native ETH is the currency address(0).
 */

export type PoolVenue = "uniswap-v3" | "uniswap-v4" | "slipstream"

export const VENUE_NAMES: Readonly<Record<PoolVenue, string>> = {
  "uniswap-v3": "Uniswap v3",
  "uniswap-v4": "Uniswap v4",
  slipstream: "Aero Slipstream",
}

export type PoolToken = {
  /** Swap asset id (`eth`, `usdc`, …). */
  assetId: string
  symbol: string
  /** ERC-20 address; for native ETH, the WETH address (used by Uniswap v3 and Slipstream). */
  address: Address
  decimals: number
  /** Native ETH: Uniswap v4 trades it as address(0). */
  isNative?: boolean
}

/** A Uniswap v4 pool key without the currencies: hookless pools only. */
export type V4PoolKey = { fee: number; tickSpacing: number }

export type VenueConfig =
  | {
      venue: "uniswap-v3" | "slipstream"
      quoter: Address
      /** Uniswap v3 fee tiers (500 = 0.05 %) or Slipstream tick spacings to try for each hop. */
      poolKeys: readonly number[]
    }
  | {
      venue: "uniswap-v4"
      quoter: Address
      poolKeys: readonly V4PoolKey[]
    }

export type OnchainPoolsConfig = {
  chainId: number
  tokens: readonly PoolToken[]
  venues: readonly VenueConfig[]
  /** Asset ids a two-hop route may pass through (for example `weth`, `usdc`). */
  connectorAssetIds: readonly string[]
  /** Seconds a quote stays valid. */
  quoteValiditySeconds?: number
  /** USD cost of a swap using `gas` units, when known. */
  networkFeeUsd?: (gas: bigint) => Promise<number> | number
  /** USD price of an asset, when known; used to compare routes net of gas. */
  priceUsd?: (assetId: string) => number | undefined
}

/** The read the provider needs from a chain client (viem's PublicClient satisfies it). */
export type QuoterClient = {
  readContract(args: {
    address: Address
    abi: typeof QUOTER_V2_ABI | typeof V4_QUOTER_ABI
    functionName: "quoteExactInput"
    args: readonly unknown[]
  }): Promise<unknown>
}

export const QUOTER_V2_ABI = [
  {
    type: "function",
    name: "quoteExactInput",
    // The quoter reverts internally to compute the result; it is read with eth_call.
    stateMutability: "view",
    inputs: [
      { name: "path", type: "bytes" },
      { name: "amountIn", type: "uint256" },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "sqrtPriceX96AfterList", type: "uint160[]" },
      { name: "initializedTicksCrossedList", type: "uint32[]" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
] as const

export const V4_QUOTER_ABI = [
  {
    type: "function",
    name: "quoteExactInput",
    stateMutability: "view",
    inputs: [
      {
        name: "params",
        type: "tuple",
        components: [
          { name: "exactCurrency", type: "address" },
          {
            name: "path",
            type: "tuple[]",
            components: [
              { name: "intermediateCurrency", type: "address" },
              { name: "fee", type: "uint24" },
              { name: "tickSpacing", type: "int24" },
              { name: "hooks", type: "address" },
              { name: "hookData", type: "bytes" },
            ],
          },
          { name: "exactAmount", type: "uint128" },
        ],
      },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
] as const

/** A route: tokens and the pool key of each hop between them. */
export type PoolRoute<Key = number | V4PoolKey> = { tokens: readonly PoolToken[]; poolKeys: readonly Key[] }

/** Packed QuoterV2 path (Uniswap v3, Slipstream): token, then per hop its 3-byte pool key and the next token. */
export function encodePoolPath(route: PoolRoute<number>, venue: "uniswap-v3" | "slipstream"): Hex {
  const types: ("address" | "uint24" | "int24")[] = []
  const values: (Address | number)[] = []
  route.tokens.forEach((token, index) => {
    if (index > 0) {
      types.push(venue === "uniswap-v3" ? "uint24" : "int24")
      values.push(route.poolKeys[index - 1]!)
    }
    types.push("address")
    values.push(token.address)
  })
  return encodePacked(types, values)
}

/** Uniswap v4 currency of a token: address(0) for native ETH. */
export function v4Currency(token: PoolToken): Address {
  return token.isNative ? zeroAddress : token.address
}

/** V4Quoter `quoteExactInput` params for a route of hookless pools. */
export function v4QuoteParams(route: PoolRoute<V4PoolKey>, amountIn: bigint) {
  return {
    exactCurrency: v4Currency(route.tokens[0]!),
    path: route.tokens.slice(1).map((token, index) => ({
      intermediateCurrency: v4Currency(token),
      fee: route.poolKeys[index]!.fee,
      tickSpacing: route.poolKeys[index]!.tickSpacing,
      hooks: zeroAddress,
      hookData: "0x" as Hex,
    })),
    exactAmount: amountIn,
  }
}

function sameCurrency(a: PoolToken, b: PoolToken, venue: PoolVenue): boolean {
  return venue === "uniswap-v4" ? v4Currency(a) === v4Currency(b) : a.address === b.address
}

/** Direct routes over every pool key, then one-hop routes through each connector. */
export function candidateRoutes<Key>(
  config: OnchainPoolsConfig,
  venue: PoolVenue,
  poolKeys: readonly Key[],
  input: PoolToken,
  output: PoolToken,
): PoolRoute<Key>[] {
  if (sameCurrency(input, output, venue)) return []
  const routes: PoolRoute<Key>[] = poolKeys.map((key) => ({ tokens: [input, output], poolKeys: [key] }))
  for (const connectorId of config.connectorAssetIds) {
    const connector = config.tokens.find((token) => token.assetId === connectorId)
    if (!connector || sameCurrency(connector, input, venue) || sameCurrency(connector, output, venue)) continue
    for (const first of poolKeys) {
      for (const second of poolKeys) {
        routes.push({ tokens: [input, connector, output], poolKeys: [first, second] })
      }
    }
  }
  return routes
}

function toUnits(amount: number, decimals: number): bigint {
  if (!Number.isFinite(amount) || amount <= 0) return 0n
  return parseUnits(amount.toFixed(Math.min(decimals, 18)), decimals)
}

function routeFeeBps(venue: PoolVenue, route: PoolRoute): number {
  // Uniswap fees are in hundredths of a basis point; a Slipstream path carries no fee.
  if (venue === "slipstream") return 0
  const keep = route.poolKeys.reduce<number>((product, key) => {
    const fee = typeof key === "number" ? key : key.fee
    return product * (1 - fee / 1_000_000)
  }, 1)
  return Math.round((1 - keep) * 10_000 * 100) / 100
}

type RouteQuote = { venue: VenueConfig; route: PoolRoute; amountOut: bigint; gasEstimate: bigint }

async function quoteRoute(
  client: QuoterClient,
  venue: VenueConfig,
  route: PoolRoute,
  amountIn: bigint,
): Promise<RouteQuote | null> {
  try {
    if (venue.venue === "uniswap-v4") {
      const [amountOut, gasEstimate] = (await client.readContract({
        address: venue.quoter,
        abi: V4_QUOTER_ABI,
        functionName: "quoteExactInput",
        args: [v4QuoteParams(route as PoolRoute<V4PoolKey>, amountIn)],
      })) as readonly [bigint, bigint]
      return amountOut > 0n ? { venue, route, amountOut, gasEstimate } : null
    }
    const [amountOut, , , gasEstimate] = (await client.readContract({
      address: venue.quoter,
      abi: QUOTER_V2_ABI,
      functionName: "quoteExactInput",
      args: [encodePoolPath(route as PoolRoute<number>, venue.venue), amountIn],
    })) as readonly [bigint, readonly bigint[], readonly number[], bigint]
    return amountOut > 0n ? { venue, route, amountOut, gasEstimate } : null
  } catch {
    // No pool at this key, or not enough liquidity on the route.
    return null
  }
}

function emptyQuote(request: SwapQuoteRequest, name: string, now: number, status: SwapQuote["status"]): SwapQuote {
  return {
    id: `quote-${request.inputAssetId}-${request.outputAssetId}-${now}`,
    status,
    provider: name,
    chainId: request.chainId,
    inputAssetId: request.inputAssetId,
    outputAssetId: request.outputAssetId,
    inputAmount: request.inputAmount,
    estimatedOutputAmount: 0,
    minimumOutputAmount: 0,
    exchangeRate: 0,
    feeAmount: 0,
    feeBps: 0,
    priceImpactPct: 0,
    slippageBps: request.slippageBps,
    networkFeeUsd: 0,
    expiresAt: now,
    createdAt: now,
    route: [],
    ...(status === "unsupported" ? { rejectionReason: "unsupported_pair" as const } : {}),
  }
}

/** The provider name before a route is chosen: the chain's venues. */
function providerName(config: OnchainPoolsConfig): string {
  return config.venues.map((venue) => VENUE_NAMES[venue.venue]).join(" / ")
}

export function createOnchainPoolsProvider(
  config: OnchainPoolsConfig,
  client: QuoterClient,
  clock: () => number = Date.now,
): SwapQuoteProvider {
  const name = providerName(config)
  return {
    id: "onchain-pools",
    name,
    async quote(request) {
      const now = clock()
      const input = config.tokens.find((token) => token.assetId === request.inputAssetId)
      const output = config.tokens.find((token) => token.assetId === request.outputAssetId)
      if (request.chainId !== config.chainId || !input || !output) return emptyQuote(request, name, now, "unsupported")
      const amountIn = toUnits(request.inputAmount, input.decimals)
      if (amountIn === 0n) return emptyQuote(request, name, now, "idle")

      const attempts = config.venues.flatMap((venue) =>
        candidateRoutes<number | V4PoolKey>(config, venue.venue, venue.poolKeys, input, output).map((route) =>
          quoteRoute(client, venue, route, amountIn),
        ),
      )
      const quotes = (await Promise.all(attempts)).filter((quote): quote is RouteQuote => quote !== null)
      if (quotes.length === 0) return emptyQuote(request, name, now, "unsupported")

      // Best output net of gas: compare in USD when the output price is known, else by output alone.
      const outputPrice = config.priceUsd?.(output.assetId)
      const scored = await Promise.all(
        quotes.map(async (quote) => {
          const gasUsd = config.networkFeeUsd ? await config.networkFeeUsd(quote.gasEstimate) : 0
          const out = Number(formatUnits(quote.amountOut, output.decimals))
          return { quote, gasUsd, score: outputPrice ? out * outputPrice - gasUsd : out }
        }),
      )
      const best = scored.reduce((a, b) => (b.score > a.score ? b : a))

      // Price impact against the same route quoted for a thousandth of the amount.
      const probeIn = amountIn / 1000n > 0n ? amountIn / 1000n : 1n
      const probe = await quoteRoute(client, best.quote.venue, best.quote.route, probeIn)
      const outAmount = Number(formatUnits(best.quote.amountOut, output.decimals))
      const exchangeRate = outAmount / request.inputAmount
      const probeRate = probe
        ? Number(formatUnits(probe.amountOut, output.decimals)) / Number(formatUnits(probeIn, input.decimals))
        : exchangeRate
      const priceImpactPct = probeRate > 0 ? Math.max(0, (1 - exchangeRate / probeRate) * 100) : 0
      const feeBps = routeFeeBps(best.quote.venue.venue, best.quote.route)

      return {
        id: `quote-${request.inputAssetId}-${request.outputAssetId}-${now}`,
        status: "valid",
        provider: VENUE_NAMES[best.quote.venue.venue],
        chainId: request.chainId,
        inputAssetId: request.inputAssetId,
        outputAssetId: request.outputAssetId,
        inputAmount: request.inputAmount,
        estimatedOutputAmount: outAmount,
        minimumOutputAmount: (outAmount * (10_000 - request.slippageBps)) / 10_000,
        exchangeRate,
        feeAmount: (request.inputAmount * feeBps) / 10_000,
        feeBps,
        priceImpactPct,
        slippageBps: request.slippageBps,
        networkFeeUsd: best.gasUsd,
        expiresAt: now + (config.quoteValiditySeconds ?? 30) * 1000,
        createdAt: now,
        route: best.quote.route.tokens.map((token) => token.symbol),
      }
    },
  }
}
