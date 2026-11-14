// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { v } from "convex/values"
import { ASK_AI_CONFIG, ASK_AI_WALLET_REQUIRED } from "./lib/askAI/config"
import type { AskAIMarketSource } from "./lib/askAI/providers/contracts"
import { internalQuery, query, type MutationCtx, type QueryCtx } from "./_generated/server"
import { getAuthedWallet } from "./walletAuth"
import { loadWorld, snapshotRows } from "./model.ts"
import type { Id } from "./_generated/dataModel"

/** Money is shown to the cent, so the model is handed cents (not 962728.1321171904). */
const toCents = (usd: number) => Math.round(usd * 100) / 100

/**
 * Rounds every `*Usd` total to the cent, then rebuilds Net Value from the ROUNDED components so
 * "Lend + Borrow + Liquid = Net value" still adds up exactly in what the user reads.
 */
export function toCentsTotals<T extends Record<string, unknown>>(totals: T): T {
  const rounded: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(totals)) {
    rounded[key] = key.endsWith("Usd") && typeof value === "number" && Number.isFinite(value) ? toCents(value) : value
  }
  const parts = ["lendNetValueUsd", "borrowNetValueUsd", "liquidNetValueUsd"] as const
  if (parts.every((key) => typeof rounded[key] === "number")) {
    rounded.netValueUsd = toCents(parts.reduce((sum, key) => sum + (rounded[key] as number), 0))
  }
  return rounded as T
}

type PortfolioReadCtx = Pick<QueryCtx | MutationCtx, "auth" | "db">

function withTurnWallet(ctx: Pick<QueryCtx, "db">, wallet?: string): PortfolioReadCtx {
  return {
    db: ctx.db,
    auth: {
      getUserIdentity: async () =>
        ({
          subject: wallet ?? "ask-guest:scheduled",
          ...(wallet ? { wallet } : {}),
        }) as Awaited<ReturnType<QueryCtx["auth"]["getUserIdentity"]>>,
    },
  }
}

async function readRunningTurnWallet(ctx: Pick<QueryCtx, "db">, turnId: Id<"askAITurns">) {
  const turn = await ctx.db.get(turnId)
  if (!turn || turn.status !== "running") throw new Error("Ask AI turn is not running")
  return turn.wallet
}

// Scheduled actions have no client auth: the queue stamped this wallet from the authenticated
// identity, and a model can only supply the running turn ID internally.
export const aaveWalletForTurn = internalQuery({
  args: { turnId: v.id("askAITurns") },
  handler: async (ctx, { turnId }) => (await readRunningTurnWallet(ctx, turnId)) ?? null,
})


/**
 * The wallet tools (portfolio, engine snapshot, borrow capacity, position risk, borrow simulation,
 * stress) read a wallet's positions. Those will come from live chain reads (Lens `getAccount`, the
 * Lend Spoke's supplied assets) in a Convex action; until that lands each tool answers that the
 * data is not available yet, never with figures from another source.
 */
const WALLET_DATA_UNAVAILABLE = "Wallet positions are not available yet in Ask AI. Avana reads them from the chain, which is coming soon."

async function walletDataUnavailable(ctx: Pick<QueryCtx | MutationCtx, "auth">) {
  const wallet = await getAuthedWallet(ctx)
  if (!wallet) return { walletRequired: true as const, message: ASK_AI_WALLET_REQUIRED }
  return { unavailable: true as const, message: WALLET_DATA_UNAVAILABLE }
}

async function walletDataUnavailableForTurn(ctx: Pick<QueryCtx, "db">, turnId: Id<"askAITurns">) {
  const wallet = await readRunningTurnWallet(ctx, turnId)
  return walletDataUnavailable(withTurnWallet(ctx, wallet ?? undefined))
}

export const portfolio = query({ args: {}, handler: (ctx) => walletDataUnavailable(ctx) })

export const portfolioForTurn = internalQuery({
  args: { turnId: v.id("askAITurns") },
  handler: (ctx, { turnId }) => walletDataUnavailableForTurn(ctx, turnId),
})

const engineSnapshotArgs = {
  lendProjectionDays: v.optional(v.number()),
}

export const engineSnapshot = query({ args: engineSnapshotArgs, handler: (ctx) => walletDataUnavailable(ctx) })

export const engineSnapshotForTurn = internalQuery({
  args: { turnId: v.id("askAITurns"), ...engineSnapshotArgs },
  handler: (ctx, { turnId }) => walletDataUnavailableForTurn(ctx, turnId),
})

export const borrowCapacity = query({ args: {}, handler: (ctx) => walletDataUnavailable(ctx) })

export const borrowCapacityForTurn = internalQuery({
  args: { turnId: v.id("askAITurns") },
  handler: (ctx, { turnId }) => walletDataUnavailableForTurn(ctx, turnId),
})

export const positionRisk = query({
  args: { positionId: v.optional(v.string()) },
  handler: (ctx) => walletDataUnavailable(ctx),
})

export const positionRiskForTurn = internalQuery({
  args: { turnId: v.id("askAITurns"), positionId: v.optional(v.string()) },
  handler: (ctx, { turnId }) => walletDataUnavailableForTurn(ctx, turnId),
})

const simulateBorrowArgs = {
  positionId: v.string(),
  additionalBorrowAmount: v.number(),
  borrowAsset: v.string(),
  projectionDays: v.optional(v.number()),
}

export const simulateBorrow = query({ args: simulateBorrowArgs, handler: (ctx) => walletDataUnavailable(ctx) })

export const simulateBorrowForTurn = internalQuery({
  args: { turnId: v.id("askAITurns"), ...simulateBorrowArgs },
  handler: (ctx, { turnId }) => walletDataUnavailableForTurn(ctx, turnId),
})

const stressPositionArgs = {
  positionId: v.string(),
  assetPriceChanges: v.array(v.object({ symbol: v.string(), change: v.number() })),
}

export const stressPosition = query({ args: stressPositionArgs, handler: (ctx) => walletDataUnavailable(ctx) })

export const stressPositionForTurn = internalQuery({
  args: { turnId: v.id("askAITurns"), ...stressPositionArgs },
  handler: (ctx, { turnId }) => walletDataUnavailableForTurn(ctx, turnId),
})

export async function readAskAIMarketSnapshots(
  ctx: Pick<QueryCtx | MutationCtx, "db">,
  {
    sources,
    kind,
    limit,
  }: {
    sources?: AskAIMarketSource[]
    kind?: "token_price" | "dex_pool" | "lending_market"
    limit?: number
  },
) {
  const boundedLimit = Math.min(Math.max(limit ?? 10, 1), 50)
  const rows = sources
    ? (
        await Promise.all(
          sources.map((source) =>
            kind
              ? ctx.db
                  .query("askAIMarketSnapshots")
                  .withIndex("by_source_kind_key", (q) => q.eq("source", source).eq("kind", kind))
                  .take(boundedLimit)
              : ctx.db
                  .query("askAIMarketSnapshots")
                  .withIndex("by_source_kind_key", (q) => q.eq("source", source))
                  .take(boundedLimit),
          ),
        )
      ).flat()
    : await ctx.db.query("askAIMarketSnapshots").withIndex("by_fetched_at").order("desc").take(boundedLimit)
  return rows
    .filter((row) => !kind || row.kind === kind)
    .filter((row) => marketFreshness(row.kind, row.sourceUpdatedAt ?? row.fetchedAt, Date.now()) === "fresh")
    .sort((left, right) => right.fetchedAt - left.fetchedAt)
    .slice(0, boundedLimit)
}

export const marketSnapshots = query({
  args: {
    sources: v.optional(v.array(v.union(v.literal("coingecko"), v.literal("defillama"), v.literal("aave")))),
    kind: v.optional(v.union(v.literal("token_price"), v.literal("dex_pool"), v.literal("lending_market"))),
    limit: v.optional(v.number()),
  },
  handler: readAskAIMarketSnapshots,
})

export function marketFreshness(kind: "token_price" | "dex_pool" | "lending_market", at: number, now = Date.now()) {
  const threshold =
    kind === "dex_pool"
      ? ASK_AI_CONFIG.freshness.poolMetricsStaleAfterMs
      : kind === "lending_market"
        ? ASK_AI_CONFIG.freshness.aaveMarketStaleAfterMs
        : ASK_AI_CONFIG.freshness.tokenPriceStaleAfterMs
  return now - at <= threshold ? ("fresh" as const) : ("stale" as const)
}

// Filler words that match everything ("on" is a substring of many payloads) and drown out the
// meaningful terms in a natural question.
const ASK_AI_SEARCH_STOPWORDS = new Set([
  "the",
  "is",
  "are",
  "was",
  "on",
  "in",
  "of",
  "to",
  "for",
  "and",
  "or",
  "a",
  "an",
  "what",
  "whats",
  "which",
  "best",
  "top",
  "highest",
  "biggest",
  "largest",
  "good",
  "great",
  "show",
  "me",
  "my",
  "our",
  "i",
  "do",
  "does",
  "how",
  "now",
  "current",
  "currently",
  "price",
  "prices",
  "rate",
  "rates",
  "market",
  "markets",
  "pool",
  "pools",
  "token",
  "tokens",
  "asset",
  "assets",
])

const ASK_AI_SEARCH_TERM_ALIASES = new Map([
  ["bitcoin", "btc"],
  ["ethereum", "eth"],
  ["chainlink", "link"],
  ["uniswap", "uni"],
  ["arbitrum", "arb"],
  ["optimism", "op"],
  ["aerodrome", "aero"],
  ["curve", "crv"],
  ["tether", "usdt"],
])

const ASK_AI_PRICE_SYMBOLS = new Set([
  "aave",
  "aero",
  "arb",
  "bal",
  "btc",
  "cbbtc",
  "cbeth",
  "crv",
  "crvusd",
  "dai",
  "eth",
  "eurc",
  "frxusd",
  "gho",
  "gno",
  "ldo",
  "link",
  "op",
  "reth",
  "rlusd",
  "steth",
  "uni",
  "usdc",
  "usde",
  "usdg",
  "usdt",
  "wbtc",
  "weeth",
  "weth",
  "wsteth",
])

const ASK_AI_PRICE_TERM_SYMBOLS = new Map<string, string[]>([
  ["btc", ["btc", "wbtc", "cbbtc"]],
  ["eth", ["eth", "weth", "steth", "wsteth", "reth", "weeth", "cbeth"]],
])

// Match on the payload's project/symbol/chain: the snapshot `key` is often an opaque hash
// ("defillama:0x…"), so key+source alone never finds a pool by name.
function askAISnapshotHaystack(snapshot: { source: string; kind: string; key: string; payload: unknown }): string {
  const payload = (snapshot.payload ?? {}) as Record<string, unknown>
  const fields = [
    snapshot.source,
    snapshot.kind,
    snapshot.key,
    payload.symbol,
    payload.project,
    payload.chain,
    payload.market,
    payload.name,
    payload.id,
  ]
  return fields
    .filter((value) => typeof value === "string")
    .join(" ")
    .toLowerCase()
}

// Rank magnitude so "best/top/largest" surfaces the deepest markets first.
function askAISnapshotSize(payload: unknown): number {
  const row = (payload ?? {}) as Record<string, unknown>
  const candidate = row.tvlUsd ?? row.totalValueLockedUSD ?? row.sizeUsd ?? row.availableLiquidity
  return typeof candidate === "number" && Number.isFinite(candidate) ? candidate : 0
}

function finiteMarketNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined
}

function compactMarketData(kind: "token_price" | "dex_pool" | "lending_market", payload: unknown) {
  const row = (payload ?? {}) as Record<string, unknown>
  const fields: Record<string, unknown> =
    kind === "token_price"
      ? {
          symbol: row.symbol,
          priceUsd: finiteMarketNumber(row.price) ?? finiteMarketNumber(row.priceUsd) ?? finiteMarketNumber(row.usd),
          confidence: finiteMarketNumber(row.confidence),
          status: row.status,
        }
      : kind === "dex_pool"
        ? {
            pool: row.pool ?? row.id,
            project: row.project,
            chain: row.chain,
            symbol: row.symbol,
            tvlUsd:
              finiteMarketNumber(row.tvlUsd) ??
              finiteMarketNumber(row.totalValueLockedUSD) ??
              finiteMarketNumber(row.liquidityUsd),
            volume24hUsd: finiteMarketNumber(row.volume24hUsd) ?? finiteMarketNumber(row.volume24h),
            apyPct: finiteMarketNumber(row.apy),
          }
        : {
            market: row.market,
            chainId: row.chainId,
            version: row.version,
            maxLtvPct: finiteMarketNumber(row.maxLtvPct),
            liquidationThresholdPct: finiteMarketNumber(row.liquidationThresholdPct),
            supplyCap: finiteMarketNumber(row.supplyCap),
            borrowCap: finiteMarketNumber(row.borrowCap),
            eModes: row.eModes,
            canSupply: row.canSupply,
            canBorrow: row.canBorrow,
            isFrozen: row.isFrozen,
            isPaused: row.isPaused,
            supplyCapReached: row.supplyCapReached,
            borrowCapReached: row.borrowCapReached,
            symbol: row.symbol,
            name: row.name,
            sizeUsd: finiteMarketNumber(row.sizeUsd),
            supplyApyPct: finiteMarketNumber(row.supplyApyPct),
            borrowApyPct: finiteMarketNumber(row.variableBorrowRate),
            utilizationPct: finiteMarketNumber(row.utilizationRate),
            availableLiquidityUsd: finiteMarketNumber(row.availableLiquidity),
          }
  return Object.fromEntries(Object.entries(fields).filter(([, value]) => value !== undefined))
}

export const searchMarkets = query({
  args: { query: v.string(), limit: v.optional(v.number()) },
  handler: async (ctx, { query: rawQuery, limit }) => {
    const queryText = rawQuery.trim().toLowerCase()
    if (!queryText || queryText.length > 200) throw new Error("Market query must contain 1 to 200 characters")
    const boundedLimit = Math.min(Math.max(limit ?? 10, 1), 20)
    const terms = queryText.split(/[^\p{L}\p{N}]+/u).filter(Boolean)
    // Drop filler words so "best ETH pools on Uniswap" matches "eth"/"uniswap", falling back
    // to the raw terms when the query is entirely stopwords.
    const meaningfulTerms = terms.filter((term) => term.length >= 3 && !ASK_AI_SEARCH_STOPWORDS.has(term))
    const searchTerms = (meaningfulTerms.length > 0 ? meaningfulTerms : terms).map(
      (term) => ASK_AI_SEARCH_TERM_ALIASES.get(term) ?? term,
    )
    // Bias the ranking by question kind, so a "pools" question surfaces pools and a "price"
    // question token prices even when both match the same asset term.
    const wantsPools = /\b(pool|pools|liquidity|tvl|lp)\b/.test(queryText)
    const wantsYield = /\b(yield|yields|apr|apy|rate|rates|lend|lending|supply|borrow)\b/.test(queryText)
    const wantsPrice = /\b(price|prices|worth|cost|value|quote)\b/.test(queryText)
    const wantsAaveProtocol =
      /\b(?:on|from|at)\s+aave\b/.test(queryText) ||
      /\baave(?:\s+v[34])?\s+(?:lend|lending|market|markets|pool|pools|apy|apr|rate|rates)\b/.test(queryText)
    const wantsAvanaOnly = /\bavana\b/.test(queryText) && !/\b(aave|compare|versus|vs)\b/.test(queryText)
    const wantsAaveOnly = /\baave\b/.test(queryText) && !wantsPrice && !/\b(avana|compare|versus|vs)\b/.test(queryText)
    const minimumYieldMatch = queryText.match(
      /\b(?:at least|above|over|more than|minimum(?: of)?)\s+(\d+(?:\.\d+)?)\s*%/,
    )
    const minimumYieldPct = minimumYieldMatch ? Number(minimumYieldMatch[1]) : null
    const kindBoost = (kind: "token_price" | "dex_pool" | "lending_market") =>
      (wantsPools && kind === "dex_pool" ? 2 : wantsPools && kind === "lending_market" ? 1 : 0) +
      (wantsYield && kind === "lending_market" ? 2 : wantsYield && kind === "dex_pool" ? 1 : 0) +
      (wantsPrice && kind === "token_price" ? 1 : 0)

    // Price questions are the highest-volume Ask AI read, so resolve ONLY the symbols named in
    // the prompt through indexes — collecting every price and history point per request does
    // not stay O(symbols requested) as the cache grows.
    const requestedSymbols = [
      ...new Set(
        searchTerms
          .filter((term) => ASK_AI_PRICE_SYMBOLS.has(term))
          .flatMap((term) => ASK_AI_PRICE_TERM_SYMBOLS.get(term) ?? [term])
          .slice(0, boundedLimit),
      ),
    ]
    const tokenPrices = (
      await Promise.all(
        requestedSymbols.map((symbol) =>
          ctx.db
            .query("tokenPrices")
            .withIndex("by_symbol", (q) => q.eq("symbol", symbol))
            .unique(),
        ),
      )
    ).filter((price): price is NonNullable<typeof price> => Boolean(price))
    const historyRows = await Promise.all(
      tokenPrices.map(async (price) => ({
        symbol: price.symbol,
        rows: await ctx.db
          .query("tokenPricesHistory")
          .withIndex("by_symbol_day", (q) => q.eq("symbol", price.symbol))
          .order("desc")
          .take(90),
      })),
    )
    const historyBySymbol = new Map(
      historyRows.map(({ symbol, rows }) => [
        symbol,
        rows.map((point) => ({ day: point.day, priceUsd: point.priceUsd })).sort((a, b) => a.day.localeCompare(b.day)),
      ]),
    )

    // The 90 days fetched above are stripped from the model context (askAIAgent.ts compacts
    // provider rows), so derive the moves here rather than shipping the raw series.
    const priceChangePct = (history: ReadonlyArray<{ priceUsd: number }>, daysBack: number, current: number) => {
      if (!Number.isFinite(current) || current <= 0 || history.length === 0) return undefined
      const past = history[history.length - 1 - daysBack]?.priceUsd
      return typeof past === "number" && past > 0 ? ((current - past) / past) * 100 : undefined
    }
    const scoredPrices = tokenPrices
      .filter((price) => price.status !== "invalid")
      .map((price) => {
        const haystack = price.symbol.toLowerCase()
        const matched = searchTerms.filter((term) => haystack.includes(term)).length
        const history = historyBySymbol.get(price.symbol) ?? []
        const changes = {
          change24hPct: priceChangePct(history, 1, price.priceUsd),
          change7dPct: priceChangePct(history, 7, price.priceUsd),
          change30dPct: priceChangePct(history, 30, price.priceUsd),
        }
        return {
          matched,
          exact: searchTerms.includes(haystack) ? 1 : 0,
          boost: kindBoost("token_price"),
          size: 0,
          row: {
            source: "defillama" as const,
            kind: "token_price" as const,
            key: price.symbol,
            data: {
              ...compactMarketData("token_price", {
                symbol: price.symbol,
                priceUsd: price.priceUsd,
                confidence: price.confidence,
                status: price.status,
              }),
              ...Object.fromEntries(Object.entries(changes).filter(([, value]) => value !== undefined)),
            },
            history,
            asOf: price.sourceUpdatedAt ?? price.updatedAt,
            freshness: price.status === "fresh" ? ("fresh" as const) : ("stale" as const),
          },
        }
      })
      .filter((entry) => entry.matched > 0)

    if (wantsPrice && scoredPrices.length > 0) {
      return {
        markets: [],
        providerData: scoredPrices
          .sort((a, b) => b.matched - a.matched || b.exact - a.exact)
          .slice(0, boundedLimit)
          .map((entry) => entry.row),
      }
    }

    const [marketRows, snapshots] = await Promise.all([
      loadWorld(ctx).then((world) => snapshotRows(ctx, world, Math.floor(Date.now() / 1000))),
      wantsAaveOnly
        ? ctx.db
            .query("askAIMarketSnapshots")
            .withIndex("by_source_kind_key", (q) => q.eq("source", "aave"))
            .take(1500)
        : wantsPools && !wantsYield
          ? ctx.db
              .query("askAIMarketSnapshots")
              .withIndex("by_source_kind_key", (q) => q.eq("source", "defillama").eq("kind", "dex_pool"))
              .take(250)
          : ctx.db.query("askAIMarketSnapshots").withIndex("by_fetched_at").order("desc").take(250),
    ])
    const markets = marketRows
    const matchingMarkets = (wantsAaveProtocol || wantsAaveOnly ? [] : markets)
      .filter((market) => {
        const haystack = `${market.slug} ${market.name} ${market.symbol} ${market.venueLabel ?? ""}`.toLowerCase()
        return searchTerms.some((term) => haystack.includes(term))
      })
      .slice(0, boundedLimit)

    // Score canonical prices and cached snapshots on the SAME scale before ranking, or token
    // prices (added first) crowd out deep pools.
    const scoredSnapshots = (wantsAvanaOnly ? [] : snapshots)
      .filter((snapshot) => marketFreshness(snapshot.kind, snapshot.sourceUpdatedAt ?? snapshot.fetchedAt) === "fresh")
      .map((snapshot) => {
        const haystack = askAISnapshotHaystack(snapshot)
        const matched = searchTerms.filter((term) => haystack.includes(term)).length
        const data = compactMarketData(snapshot.kind, snapshot.payload)
        const symbol = typeof data.symbol === "string" ? data.symbol.toLowerCase() : ""
        return {
          matched,
          exact: symbol.length > 0 && searchTerms.includes(symbol) ? 1 : 0,
          boost: kindBoost(snapshot.kind),
          size: askAISnapshotSize(snapshot.payload),
          row: {
            source: snapshot.source,
            kind: snapshot.kind,
            key: snapshot.key,
            data,
            asOf: snapshot.sourceUpdatedAt ?? snapshot.fetchedAt,
            freshness: marketFreshness(snapshot.kind, snapshot.sourceUpdatedAt ?? snapshot.fetchedAt),
          },
          yieldPct:
            typeof data.supplyApyPct === "number"
              ? data.supplyApyPct
              : typeof data.apyPct === "number"
                ? data.apyPct
                : Number.NEGATIVE_INFINITY,
        }
      })
      .filter(
        (entry) =>
          entry.matched > 0 &&
          (!wantsAaveProtocol || entry.row.source === "aave") &&
          (!wantsYield || entry.row.kind === "lending_market" || entry.row.kind === "dex_pool"),
      )

    const providerData = [...scoredPrices, ...scoredSnapshots]
      // Most query terms matched, then the kind the question asked for, then depth.
      .sort((a, b) => {
        if (minimumYieldPct !== null && "yieldPct" in a && "yieldPct" in b) {
          const aMeets = a.yieldPct >= minimumYieldPct
          const bMeets = b.yieldPct >= minimumYieldPct
          if (aMeets !== bMeets) return aMeets ? -1 : 1
          if (a.yieldPct !== b.yieldPct) return b.yieldPct - a.yieldPct
        }
        return b.matched - a.matched || b.boost - a.boost || b.exact - a.exact || b.size - a.size
      })
      .slice(0, boundedLimit)
      .map((entry) => entry.row)

    return { markets: matchingMarkets, providerData }
  },
})

export const poolMetrics = query({
  args: { marketId: v.string() },
  handler: async (ctx, { marketId }) => {
    const normalizedId = marketId.trim().toLowerCase()
    if (!normalizedId || normalizedId.length > 160) throw new Error("Market ID is invalid")
    const snapshots = await ctx.db.query("askAIMarketSnapshots").withIndex("by_fetched_at").order("desc").take(100)
    // The market's services/convex snapshot row, by slug or symbol.
    const rows = await snapshotRows(ctx, await loadWorld(ctx), Math.floor(Date.now() / 1000))
    const market =
      rows.find((row) => row.slug.toLowerCase() === normalizedId) ??
      rows.find((row) => row.symbol.toLowerCase() === normalizedId) ??
      null
    const aliases = new Set([normalizedId, market?.slug.toLowerCase(), market?.symbol.toLowerCase()].filter(Boolean))
    const providerData = snapshots
      .filter((snapshot) => snapshot.kind === "dex_pool" && aliases.has(snapshot.key.toLowerCase()))
      .filter((snapshot) => marketFreshness("dex_pool", snapshot.sourceUpdatedAt ?? snapshot.fetchedAt) === "fresh")
      .map((snapshot) => ({
        source: snapshot.source,
        data: snapshot.payload,
        asOf: snapshot.sourceUpdatedAt ?? snapshot.fetchedAt,
        freshness: marketFreshness("dex_pool", snapshot.sourceUpdatedAt ?? snapshot.fetchedAt),
      }))
    if (!market && providerData.length === 0) throw new Error("Market not found")
    return { market: market ?? null, providerData }
  },
})
