// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
/**
 * DefiLlama prices of tokens outside the protocol, for display only (wallet tab, swap, Ask AI).
 * Every protocol value (collateral, debt, health factor, fee) uses the on-chain oracle rows served
 * by `prices.ts`, never these. Flow: cron → refreshPrices (action, fetch from DefiLlama) →
 * upsertPrices (mutation) → getPrices / getPriceSnapshot (queries).
 */

import { v } from "convex/values"
import { internalAction, internalMutation, query, type MutationCtx, type QueryCtx } from "./_generated/server"
import { internal } from "./_generated/api"

/**
 * Base symbol (lowercase) → DefiLlama coin id. A symbol not listed here has no off-protocol price
 * and shows as unavailable. Ids use the mainnet contract where the token lives on Ethereum, a
 * coingecko slug for L2-native/non-ERC20 assets.
 */
export const TOKEN_LLAMA_IDS: Record<string, string> = {
  usdc: "ethereum:0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  usdt: "ethereum:0xdAC17F958D2ee523a2206206994597C13D831ec7",
  dai: "ethereum:0x6B175474E89094C44Da98b954EedeAC495271d0F",
  weth: "ethereum:0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  wbtc: "ethereum:0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
  btc: "coingecko:bitcoin",
  crvusd: "ethereum:0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E",
  gho: "ethereum:0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f",
  eth: "coingecko:ethereum",
  steth: "ethereum:0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
  wsteth: "ethereum:0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
  reth: "ethereum:0xae78736Cd615f374D3085123A210448E74Fc6393",
  weeth: "ethereum:0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee",
  eurc: "ethereum:0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c",
  cbeth: "ethereum:0xBe9895146f7AF43049ca1c1AE358B0541Ea49704",
  cbbtc: "ethereum:0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf",
  aave: "coingecko:aave",
  uni: "coingecko:uniswap",
  crv: "coingecko:curve-dao-token",
  // Governance / L2 tokens.
  link: "ethereum:0x514910771AF9Ca656af840dff83E8264EcF986CA",
  arb: "coingecko:arbitrum",
  op: "coingecko:optimism",
  gno: "ethereum:0x6810e776880C02933D47DB1b9fc05908e5386b96",
  ldo: "ethereum:0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32",
  bal: "ethereum:0xba100000625a3754423978a60c9317c58a424e3D",
  aero: "coingecko:aerodrome-finance",
  // Stablecoins (≈ $1, but track the real depeg instead of a pinned fixture).
  usde: "coingecko:ethena-usde",
  frxusd: "coingecko:frax-usd",
  usdg: "coingecko:global-dollar",
  rlusd: "coingecko:ripple-usd",
}

/**
 * Freshness thresholds against the 10-minute refresh cron: one missed run (20m) is `stale`,
 * several (45m) `invalid`, so a wedged cron surfaces without tripping on one network blip. A
 * failed refresh writes nothing, so rows age past these honestly.
 */
export const PRICE_REFRESH_INTERVAL_MS = 10 * 60 * 1000
export const PRICE_STALE_AFTER_MS = 20 * 60 * 1000
export const PRICE_INVALID_AFTER_MS = 45 * 60 * 1000

/** DefiLlama chain-name → EVM chainId, for parsing `chain:address` coin ids. */
const LLAMA_CHAIN_IDS: Record<string, number> = {
  ethereum: 1,
  base: 8453,
  arbitrum: 42161,
  optimism: 10,
  polygon: 137,
}

/** Parse a DefiLlama coin id into on-chain identity. coingecko-slug ids carry no contract. */
export function parseLlamaId(llamaId: string): { chainId?: number; contractAddress?: string } {
  const [chain, ref] = llamaId.split(":")
  if (!chain || !ref || chain === "coingecko") return {}
  const chainId = LLAMA_CHAIN_IDS[chain]
  if (ref.startsWith("0x")) return { chainId, contractAddress: ref.toLowerCase() }
  return chainId ? { chainId } : {}
}

/** Classify a price row's age against the freshness thresholds. */
export function classifyPriceStatus(ageMs: number): "fresh" | "stale" | "invalid" {
  if (ageMs >= PRICE_INVALID_AFTER_MS) return "invalid"
  if (ageMs >= PRICE_STALE_AFTER_MS) return "stale"
  return "fresh"
}

/**
 * Minimum DefiLlama `confidence` (0–1) to accept a quote; tracked coins normally resolve at
 * 0.99. Below it the quote is dropped and flagged stale rather than stored as authoritative.
 * Missing confidence counts as acceptable.
 */
export const PRICE_MIN_CONFIDENCE = 0.8

const USD_PEGGED_SYMBOLS = new Set(["usdc", "usdt", "dai", "gho", "crvusd", "usde", "frxusd", "usdg", "rlusd"])
export const USD_PEGGED_MIN_PRICE = 0.5
export const USD_PEGGED_MAX_PRICE = 1.5

/** Reject provider/identity failures without pretending that a normal market depeg cannot happen. */
export function isPlausibleTokenPrice(symbol: string, priceUsd: number) {
  if (!Number.isFinite(priceUsd) || priceUsd <= 0) return false
  if (!USD_PEGGED_SYMBOLS.has(symbol.toLowerCase())) return true
  return priceUsd >= USD_PEGGED_MIN_PRICE && priceUsd <= USD_PEGGED_MAX_PRICE
}

/** All token prices (one row per base symbol). Small table — safe to collect. */
export const getPrices = query({
  args: {},
  handler: async (ctx) => {
    const rows = await ctx.db.query("tokenPrices").collect()
    return rows.map((r) => ({
      symbol: r.symbol,
      chainId: r.chainId,
      contractAddress: r.contractAddress,
      priceUsd: r.priceUsd,
      confidence: r.confidence,
      source: r.source,
      status: r.status,
      priceChange24hWad: r.priceChange24hWad,
      updatedAt: r.updatedAt,
    }))
  },
})

async function readProviderHealth(ctx: { db: QueryCtx["db"] }, kind: "prices" | "fx") {
  return ctx.db
    .query("oracleProviderHealth")
    .withIndex("by_kind", (q) => q.eq("kind", kind))
    .unique()
}

async function writeProviderHealth(
  ctx: MutationCtx,
  args: {
    kind: "prices" | "fx"
    checkedAt: number
    sourceUpdatedAt?: number
    quoteCount: number
    written: number
    unchanged: number
  },
) {
  const existing = await readProviderHealth(ctx, args.kind)
  if (existing) {
    await ctx.db.patch(existing._id, {
      checkedAt: args.checkedAt,
      sourceUpdatedAt: args.sourceUpdatedAt,
      quoteCount: args.quoteCount,
      written: args.written,
      unchanged: args.unchanged,
    })
  } else {
    await ctx.db.insert("oracleProviderHealth", args)
  }
}

function quoteUnchanged(
  existing: {
    priceUsd: number
    confidence?: number
    source: string
    status?: string
    llamaId: string
  },
  row: {
    priceUsd: number
    confidence?: number
    source: string
    status?: string
    llamaId: string
  },
) {
  return (
    existing.priceUsd === row.priceUsd &&
    (existing.confidence ?? null) === (row.confidence ?? null) &&
    existing.source === row.source &&
    (existing.status ?? null) === (row.status ?? null) &&
    existing.llamaId === row.llamaId
  )
}

/**
 * Price freshness signal: the OLDEST row's last-refresh time, so the UI can warn instead of
 * presenting stale numbers as live. `oracleProviderHealth` advances on every successful
 * refresh even when quotes are unchanged, keeping identical responses observable without
 * rewriting every tokenPrices document.
 *
 * MUST return raw `updatedAt` only, never an ageMs/stale computed from Date.now(): a Convex
 * query is recomputed only when a document it read changes, so a wall-clock value would
 * freeze when the client subscribed and never flip fresh→stale. The client derives age
 * against its own ticking clock (token-prices-context).
 */
export const getPriceStatus = query({
  args: {},
  handler: async (ctx) => {
    const health = await readProviderHealth(ctx, "prices")
    if (health) {
      return {
        updatedAt: health.checkedAt,
        staleAfterMs: PRICE_STALE_AFTER_MS,
        count: health.quoteCount,
      }
    }
    const rows = await ctx.db.query("tokenPrices").collect()
    if (rows.length === 0) {
      return { updatedAt: null, staleAfterMs: PRICE_STALE_AFTER_MS, count: 0 }
    }
    return {
      updatedAt: Math.min(...rows.map((r) => r.updatedAt)),
      staleAfterMs: PRICE_STALE_AFTER_MS,
      count: rows.length,
    }
  },
})

/**
 * Live price map for clients. Reads ONLY `tokenPrices` so an identical provider refresh
 * that advances `oracleProviderHealth` does not invalidate this subscription.
 * Freshness/`checkedAt` comes from `getPriceStatus`.
 */
export const getPriceSnapshot = query({
  args: {},
  handler: async (ctx) => {
    const rows = await ctx.db.query("tokenPrices").collect()
    const prices = rows.map((r) => ({
      symbol: r.symbol,
      priceUsd: r.priceUsd,
      confidence: r.confidence,
      source: r.source,
      status: r.status,
      updatedAt: r.updatedAt,
    }))
    const quoteUpdatedAt = rows.length === 0 ? null : Math.min(...rows.map((r) => r.updatedAt))
    return {
      prices,
      status: {
        updatedAt: quoteUpdatedAt,
        staleAfterMs: PRICE_STALE_AFTER_MS,
        invalidAfterMs: PRICE_INVALID_AFTER_MS,
        count: rows.length,
      },
    }
  },
})

/** Upsert price rows by symbol. Identical provider quotes write zero quote rows. */
export const upsertPrices = internalMutation({
  args: {
    rows: v.array(
      v.object({
        symbol: v.string(),
        llamaId: v.string(),
        chainId: v.optional(v.number()),
        contractAddress: v.optional(v.string()),
        priceUsd: v.number(),
        decimals: v.optional(v.number()),
        confidence: v.optional(v.number()),
        source: v.string(),
        sourceUpdatedAt: v.optional(v.number()),
        fetchedAt: v.optional(v.number()),
        snapshotAt: v.optional(v.number()),
        status: v.optional(v.union(v.literal("fresh"), v.literal("stale"), v.literal("invalid"))),
        updatedAt: v.number(),
      }),
    ),
  },
  handler: async (ctx, { rows }) => {
    let written = 0
    let unchanged = 0
    let checkedAt = 0
    let sourceUpdatedAt: number | undefined
    for (const row of rows) {
      checkedAt = Math.max(checkedAt, row.fetchedAt ?? row.updatedAt)
      if (row.sourceUpdatedAt != null) {
        sourceUpdatedAt = sourceUpdatedAt == null ? row.sourceUpdatedAt : Math.min(sourceUpdatedAt, row.sourceUpdatedAt)
      }
      const existing = await ctx.db
        .query("tokenPrices")
        .withIndex("by_symbol", (q) => q.eq("symbol", row.symbol))
        .unique()
      if (existing && quoteUnchanged(existing, row)) {
        unchanged += 1
        continue
      }
      if (existing) await ctx.db.patch(existing._id, row)
      else await ctx.db.insert("tokenPrices", row)
      written += 1
    }
    if (checkedAt === 0) checkedAt = Date.now()
    await writeProviderHealth(ctx, {
      kind: "prices",
      checkedAt,
      sourceUpdatedAt,
      quoteCount: rows.length,
      written,
      unchanged,
    })
    return { written, unchanged }
  },
})

/** Copy the current oracle rows into one closing-price history point per UTC day. */
export const snapshotDailyTokenPrices = internalMutation({
  args: { day: v.optional(v.string()) },
  handler: async (ctx, { day: requestedDay }) => {
    const day = requestedDay ?? new Date().toISOString().slice(0, 10)
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error("Token price history day must use YYYY-MM-DD")
    const prices = await ctx.db.query("tokenPrices").collect()
    const result = { inserted: 0, updated: 0, unchanged: 0 }
    for (const price of prices) {
      const existing = await ctx.db
        .query("tokenPricesHistory")
        .withIndex("by_symbol_day", (q) => q.eq("symbol", price.symbol).eq("day", day))
        .unique()
      if (!existing) {
        await ctx.db.insert("tokenPricesHistory", {
          symbol: price.symbol,
          day,
          priceUsd: price.priceUsd,
          updatedAt: price.updatedAt,
        })
        result.inserted += 1
      } else if (existing.priceUsd !== price.priceUsd) {
        await ctx.db.patch(existing._id, { priceUsd: price.priceUsd, updatedAt: price.updatedAt })
        result.updated += 1
      } else {
        result.unchanged += 1
      }
    }
    return result
  },
})

/** Historical daily price series for a token (charts). Separate from the current `getPrices`. */
export const getTokenPriceHistory = query({
  args: { symbol: v.string() },
  handler: async (ctx, { symbol }) => {
    const rows = await ctx.db
      .query("tokenPricesHistory")
      // Trailing year only: the table gains a row per token per day.
      .withIndex("by_symbol_day", (q) =>
        q
          .eq("symbol", symbol.toLowerCase())
          .gte("day", new Date(Date.now() - 365 * 86_400_000).toISOString().slice(0, 10)),
      )
      .collect()
    return rows.map((r) => ({ day: r.day, priceUsd: r.priceUsd }))
  },
})

type LlamaResponse = {
  coins: Record<string, { price: number; decimals?: number; confidence?: number; symbol?: string; timestamp?: number }>
}

/**
 * Fetch current prices from DefiLlama and upsert them. Internal-only: invoked by the
 * cron (or the CLI via `npx convex run`); never publicly callable, so anonymous
 * callers can't trigger outbound fetches or price-table writes.
 *
 * Failures are logged with a greppable `[prices]` prefix and re-thrown so the scheduled
 * run is recorded as FAILED (observable/alertable in the Convex dashboard) rather than
 * silently leaving the UI on last-known values. `getPriceStatus` then surfaces staleness.
 */
export const refreshPrices = internalAction({
  args: {},
  handler: async (ctx): Promise<{ written: number; fetched: number }> => {
    const entries = Object.entries(TOKEN_LLAMA_IDS)
    const ids = entries.map(([, id]) => id).join(",")
    try {
      const res = await fetch(`https://coins.llama.fi/prices/current/${encodeURIComponent(ids)}`)
      if (!res.ok) throw new Error(`DefiLlama request failed: ${res.status}`)
      const json = (await res.json()) as LlamaResponse
      const now = Date.now()
      const rows = entries
        .map(([symbol, llamaId]) => {
          const coin = json.coins[llamaId]
          if (!coin) return null
          // Require a finite, strictly-positive USD price: `typeof NaN === "number"` (as are 0
          // and negatives), so a plain type check would store an insane quote as authoritative
          // and divide by it downstream.
          if (!isPlausibleTokenPrice(symbol, coin.price)) return null
          // Reject quotes below the confidence threshold as too unreliable to treat as real.
          // Missing confidence is acceptable, so an omitted field never empties the batch.
          if (typeof coin.confidence === "number" && coin.confidence < PRICE_MIN_CONFIDENCE) return null
          const { chainId, contractAddress } = parseLlamaId(llamaId)
          // DefiLlama's per-coin `timestamp` is in SECONDS; absent → now, so an omitted field
          // never looks artificially ancient.
          const sourceUpdatedAt = typeof coin.timestamp === "number" ? coin.timestamp * 1000 : now
          return {
            symbol,
            llamaId,
            chainId,
            contractAddress,
            priceUsd: coin.price,
            decimals: coin.decimals,
            confidence: coin.confidence,
            source: "defillama",
            sourceUpdatedAt,
            fetchedAt: now,
            snapshotAt: now,
            status: classifyPriceStatus(Math.max(0, now - sourceUpdatedAt)),
            updatedAt: now,
          }
        })
        .filter((r): r is NonNullable<typeof r> => r !== null)
      if (rows.length === 0) {
        // Fetched but nothing usable: fail the run so the UI does not serve stale values as
        // though the refresh worked.
        throw new Error("DefiLlama returned no usable prices")
      }
      const { written: quotesWritten } = await ctx.runMutation(internal.tokenPrices.upsertPrices, { rows })
      void quotesWritten
      return { written: rows.length, fetched: Object.keys(json.coins).length }
    } catch (err) {
      console.error("[prices] refreshPrices failed; UI will surface staleness via getPriceStatus:", err)
      throw err
    }
  },
})
