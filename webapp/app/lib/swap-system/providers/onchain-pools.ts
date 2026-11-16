import { encodePacked, formatUnits, parseUnits, type Address, type Hex } from "viem"
import type { SwapQuote, SwapQuoteRequest } from "../quote-types"
import type { SwapQuoteProvider } from "./types"

/**
 * Quotes from the chain's own concentrated-liquidity pools through the venue's QuoterV2
 * (Uniswap v3 or Aerodrome Slipstream; both take `quoteExactInput(path, amountIn)` and differ only
 * in what the path carries between tokens: the fee tier or the tick spacing). It tries the direct
 * pools and the one-hop routes through the configured connector tokens and keeps the best output.
 */

export type PoolVenue = "uniswap-v3" | "slipstream"

export type PoolToken = {
  /** Swap asset id (`eth`, `usdc`, …); native ETH maps to the WETH address. */
  assetId: string
  symbol: string
  address: Address
  decimals: number
}

export type OnchainPoolsConfig = {
  chainId: number
  venue: PoolVenue
  quoter: Address
  tokens: readonly PoolToken[]
  /** Uniswap v3 fee tiers (500 = 0.05 %) or Slipstream tick spacings to try for each hop. */
  poolKeys: readonly number[]
  /** Asset ids a two-hop route may pass through (for example `weth`, `usdc`). */
  connectorAssetIds: readonly string[]
  /** Seconds a quote stays valid. */
  quoteValiditySeconds?: number
  /** USD cost of a swap using `gas` units, when known. */
  networkFeeUsd?: (gas: bigint) => Promise<number> | number
}

/** The read the provider needs from a chain client (viem's PublicClient satisfies it). */
export type QuoterClient = {
  readContract(args: {
    address: Address
    abi: typeof QUOTER_V2_ABI
    functionName: "quoteExactInput"
    args: readonly [Hex, bigint]
  }): Promise<readonly [bigint, readonly bigint[], readonly number[], bigint]>
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

/** A route: tokens and the pool key (fee tier or tick spacing) of each hop between them. */
export type PoolRoute = { tokens: readonly PoolToken[]; poolKeys: readonly number[] }

/** Packed QuoterV2 path: token, then for each hop its 3-byte pool key and the next token. */
export function encodePoolPath(route: PoolRoute, venue: PoolVenue): Hex {
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

/** Direct routes over every pool key, then one-hop routes through each connector. */
export function candidateRoutes(config: OnchainPoolsConfig, input: PoolToken, output: PoolToken): PoolRoute[] {
  const routes: PoolRoute[] = config.poolKeys.map((key) => ({ tokens: [input, output], poolKeys: [key] }))
  for (const connectorId of config.connectorAssetIds) {
    const connector = config.tokens.find((token) => token.assetId === connectorId)
    if (!connector || connector.address === input.address || connector.address === output.address) continue
    for (const first of config.poolKeys) {
      for (const second of config.poolKeys) {
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

function routeFeeBps(route: PoolRoute, venue: PoolVenue): number {
  // Uniswap v3 fee tiers are in hundredths of a basis point; Slipstream paths carry no fee.
  if (venue !== "uniswap-v3") return 0
  const keep = route.poolKeys.reduce((product, fee) => product * (1 - fee / 1_000_000), 1)
  return Math.round((1 - keep) * 10_000 * 100) / 100
}

type RouteQuote = { route: PoolRoute; amountOut: bigint; gasEstimate: bigint }

async function quoteRoute(
  client: QuoterClient,
  config: OnchainPoolsConfig,
  route: PoolRoute,
  amountIn: bigint,
): Promise<RouteQuote | null> {
  try {
    const [amountOut, , , gasEstimate] = await client.readContract({
      address: config.quoter,
      abi: QUOTER_V2_ABI,
      functionName: "quoteExactInput",
      args: [encodePoolPath(route, config.venue), amountIn],
    })
    return amountOut > 0n ? { route, amountOut, gasEstimate } : null
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

export function createOnchainPoolsProvider(
  config: OnchainPoolsConfig,
  client: QuoterClient,
  name = config.venue === "uniswap-v3" ? "Uniswap v3" : "Aerodrome Slipstream",
  clock: () => number = Date.now,
): SwapQuoteProvider {
  return {
    id: "onchain-pools",
    name,
    async quote(request) {
      const now = clock()
      const input = config.tokens.find((token) => token.assetId === request.inputAssetId)
      const output = config.tokens.find((token) => token.assetId === request.outputAssetId)
      if (request.chainId !== config.chainId || !input || !output || input.address === output.address) {
        return emptyQuote(request, name, now, "unsupported")
      }
      const amountIn = toUnits(request.inputAmount, input.decimals)
      if (amountIn === 0n) return emptyQuote(request, name, now, "idle")

      const routes = candidateRoutes(config, input, output)
      const quotes = (await Promise.all(routes.map((route) => quoteRoute(client, config, route, amountIn)))).filter(
        (quote): quote is RouteQuote => quote !== null,
      )
      if (quotes.length === 0) return emptyQuote(request, name, now, "unsupported")
      const best = quotes.reduce((a, b) => (b.amountOut > a.amountOut ? b : a))

      // Price impact against the same route quoted for a thousandth of the amount.
      const probeIn = amountIn / 1000n > 0n ? amountIn / 1000n : 1n
      const probe = await quoteRoute(client, config, best.route, probeIn)
      const outAmount = Number(formatUnits(best.amountOut, output.decimals))
      const exchangeRate = outAmount / request.inputAmount
      const probeRate = probe
        ? Number(formatUnits(probe.amountOut, output.decimals)) / Number(formatUnits(probeIn, input.decimals))
        : exchangeRate
      const priceImpactPct = probeRate > 0 ? Math.max(0, (1 - exchangeRate / probeRate) * 100) : 0
      const feeBps = routeFeeBps(best.route, config.venue)
      const networkFeeUsd = config.networkFeeUsd ? await config.networkFeeUsd(best.gasEstimate) : 0

      return {
        id: `quote-${request.inputAssetId}-${request.outputAssetId}-${now}`,
        status: "valid",
        provider: name,
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
        networkFeeUsd,
        expiresAt: now + (config.quoteValiditySeconds ?? 30) * 1000,
        createdAt: now,
        route: best.route.tokens.map((token) => token.symbol),
      }
    },
  }
}
