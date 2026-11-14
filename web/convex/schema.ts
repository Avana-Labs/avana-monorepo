/**
 * Convex schema — canonical persistence for every number a detail page renders.
 * Queries in sibling files (`engagement.ts`, `cashflow.ts`, `markets.ts`,
 * `allocation.ts`) fold these rows into the view-models in
 * `app/lib/borrow-detail/types.ts`; keep the `@convex-source` JSDoc pointers there
 * in sync when renaming a field.
 *
 * Products are siloed: `borrow*` / `lend*` / `multiply*` tables are slug-keyed and
 * must not share rows. `markets` is the legacy shared identity hub that
 * `walletEvents` / allocation still FK against.
 */

import { defineSchema, defineTable } from "convex/server"
import { v } from "convex/values"

/** Wallet actions that make a user "engaged" with a market. */
export const WALLET_EVENT_KINDS = ["supply", "withdraw", "borrow", "repay", "liquidation", "rewardsClaim"] as const

const walletEventKind = v.union(
  v.literal("supply"),
  v.literal("withdraw"),
  v.literal("borrow"),
  v.literal("repay"),
  v.literal("liquidation"),
  v.literal("rewardsClaim"),
)

/** asset = single borrowable token, pool = LP collateral, lend = single-asset supply,
 *  multiply = leveraged collateral→borrow loop. */
export const MARKET_SCOPES = ["asset", "pool", "lend", "multiply"] as const
const marketScope = v.union(v.literal("asset"), v.literal("pool"), v.literal("lend"), v.literal("multiply"))

/** Risk buckets mirror `RiskLevel` in `app/lib/borrow-detail/types.ts`. */
const riskLevel = v.union(v.literal("low"), v.literal("moderate"), v.literal("elevated"), v.literal("high"))

export default defineSchema({
  /**
   * Canonical market directory; every other table FKs against this. `slug` is the
   * URL id (e.g. `usdc`, `uni-v3-bluechip-weth-usdc`) and matches
   * `AssetDetail.id` / `PoolDetail.id`.
   */
  markets: defineTable({
    scope: marketScope,
    slug: v.string(),
    chainId: v.number(),
    name: v.string(),
    /** Short symbol (assets) or pair label (pools). */
    symbol: v.string(),
    /** Pools only, e.g. "Uniswap v3 · 0.3%". */
    venueLabel: v.optional(v.string()),
    /** Assets only. */
    category: v.optional(v.union(v.literal("stable"), v.literal("crypto"), v.literal("stock"))),
    explorerUrl: v.optional(v.string()),
    /** Caps user-visible utilization / LTV on the front end. */
    reserveFactorPct: v.optional(v.number()),
    /** Incentive APY percent (0 = none). */
    rewardsApyPct: v.optional(v.number()),
    description: v.optional(v.string()),
    iconUrl: v.optional(v.string()),
    spokeId: v.optional(v.string()),
    feeTier: v.optional(v.string()),
    maxLtvPct: v.optional(v.number()),
    /**
     * Canonical USD price, seeded per market because the live `tokenPrices` oracle only
     * covers single-token bluechip symbols. On POOL markets this is the LP token price,
     * read by the onboarding starter gate and by assertBorrowSolvent to revalue an
     * 18-decimal LP pledge.
     */
    priceUsd: v.optional(v.number()),
    /**
     * Pool composition with NORMALIZED weights (fractions summing to 1). Lets
     * `prices.refreshPoolLpPrices` recompute the LP price live as Σ(weightᵢ × priceᵢ)
     * instead of leaving it frozen at the seed value.
     */
    constituents: v.optional(v.array(v.object({ symbol: v.string(), weight: v.number() }))),
    visuals: v.optional(
      v.array(
        v.object({
          symbol: v.string(),
          shortLabel: v.string(),
          bgClassName: v.string(),
          textClassName: v.string(),
          iconUrl: v.optional(v.string()),
        }),
      ),
    ),
    resources: v.optional(v.array(v.object({ label: v.string(), href: v.string() }))),
    createdAt: v.number(),
  })
    .index("by_scope_slug", ["scope", "slug"])
    .index("by_scope_chain", ["scope", "chainId"])
    // Scope-independent point reads for Ask AI tools; a slug is globally unique in practice.
    .index("by_slug", ["slug"])
    .index("by_symbol", ["symbol"]),

  /**
   * Product-siloed borrow market identity (pool + asset). Prefer this for display
   * metadata; legacy `markets` is still the FK hub for walletEvents / allocation.
   */
  borrowMarkets: defineTable({
    slug: v.string(),
    kind: v.union(v.literal("pool"), v.literal("asset")),
    chainId: v.number(),
    name: v.string(),
    symbol: v.string(),
    venueLabel: v.optional(v.string()),
    category: v.optional(v.union(v.literal("stable"), v.literal("crypto"), v.literal("stock"))),
    explorerUrl: v.optional(v.string()),
    reserveFactorPct: v.optional(v.number()),
    rewardsApyPct: v.optional(v.number()),
    description: v.optional(v.string()),
    iconUrl: v.optional(v.string()),
    spokeId: v.optional(v.string()),
    feeTier: v.optional(v.string()),
    maxLtvPct: v.optional(v.number()),
    priceUsd: v.optional(v.number()),
    visuals: v.optional(
      v.array(
        v.object({
          symbol: v.string(),
          shortLabel: v.string(),
          bgClassName: v.string(),
          textClassName: v.string(),
          iconUrl: v.optional(v.string()),
        }),
      ),
    ),
    resources: v.optional(v.array(v.object({ label: v.string(), href: v.string() }))),
    /** Asset-scope fields: spoke-agnostic asset id + display context label. */
    baseAssetId: v.optional(v.string()),
    contextLabel: v.optional(v.string()),
    createdAt: v.number(),
  }).index("by_slug", ["slug"]),

  lendMarkets: defineTable({
    slug: v.string(),
    chainId: v.number(),
    name: v.string(),
    symbol: v.string(),
    venueLabel: v.optional(v.string()),
    category: v.optional(v.union(v.literal("stable"), v.literal("crypto"), v.literal("stock"))),
    explorerUrl: v.optional(v.string()),
    reserveFactorPct: v.optional(v.number()),
    rewardsApyPct: v.optional(v.number()),
    description: v.optional(v.string()),
    iconUrl: v.optional(v.string()),
    spokeId: v.optional(v.string()),
    feeTier: v.optional(v.string()),
    maxLtvPct: v.optional(v.number()),
    priceUsd: v.optional(v.number()),
    visuals: v.optional(
      v.array(
        v.object({
          symbol: v.string(),
          shortLabel: v.string(),
          bgClassName: v.string(),
          textClassName: v.string(),
          iconUrl: v.optional(v.string()),
        }),
      ),
    ),
    resources: v.optional(v.array(v.object({ label: v.string(), href: v.string() }))),
    createdAt: v.number(),
  }).index("by_slug", ["slug"]),

  multiplyMarkets: defineTable({
    slug: v.string(),
    chainId: v.number(),
    name: v.string(),
    symbol: v.string(),
    venueLabel: v.optional(v.string()),
    category: v.optional(v.union(v.literal("stable"), v.literal("crypto"), v.literal("stock"))),
    explorerUrl: v.optional(v.string()),
    reserveFactorPct: v.optional(v.number()),
    rewardsApyPct: v.optional(v.number()),
    description: v.optional(v.string()),
    iconUrl: v.optional(v.string()),
    spokeId: v.optional(v.string()),
    feeTier: v.optional(v.string()),
    maxLtvPct: v.optional(v.number()),
    priceUsd: v.optional(v.number()),
    visuals: v.optional(
      v.array(
        v.object({
          symbol: v.string(),
          shortLabel: v.string(),
          bgClassName: v.string(),
          textClassName: v.string(),
          iconUrl: v.optional(v.string()),
        }),
      ),
    ),
    resources: v.optional(v.array(v.object({ label: v.string(), href: v.string() }))),
    /** Multiply-specific catalog fields; optional so existing rows migrate lazily. */
    publicMaxMultiplier: v.optional(v.number()),
    hardMaxMultiplier: v.optional(v.number()),
    minHealthFactor: v.optional(v.number()),
    riskTier: v.optional(v.union(v.literal("low"), v.literal("medium"), v.literal("high"))),
    liquidationThresholdPct: v.optional(v.number()),
    collateralSymbol: v.optional(v.string()),
    collateralName: v.optional(v.string()),
    borrowSymbol: v.optional(v.string()),
    borrowName: v.optional(v.string()),
    featured: v.optional(v.boolean()),
    status: v.optional(v.string()),
    createdAt: v.number(),
  }).index("by_slug", ["slug"]),

  /**
   * Every on-chain user action; drives `EngagementTrend.*` and
   * `AssetDetail.transactions`. Write path: indexer/webhook. Read path:
   * `convex/engagement.ts`.
   */
  walletEvents: defineTable({
    marketId: v.id("markets"),
    /** EVM address, stored LOWERCASE for deterministic indexing. */
    wallet: v.string(),
    kind: walletEventKind,
    /** Notional in USD at event time (oracle price at block). */
    amountUsd: v.number(),
    /** Liquidator, router, etc. */
    counterparty: v.optional(v.string()),
    txHash: v.string(),
    blockNumber: v.number(),
    /** ms since epoch, UTC. */
    at: v.number(),
  })
    .index("by_market_at", ["marketId", "at"])
    .index("by_wallet_at", ["wallet", "at"])
    .index("by_market_kind_at", ["marketId", "kind", "at"]),

  /**
   * LEGACY shared daily market snapshot, one row per (market, day). Prefer the
   * product-siloed `borrowDailyStats` / `lendDailyStats` / `multiplyDailyStats`; kept
   * for dual-read and the seed still dual-writes. Write path: daily aggregator job.
   */
  marketDailyStats: defineTable({
    marketId: v.id("markets"),
    /** ISO YYYY-MM-DD, UTC. */
    day: v.string(),
    suppliedUsd: v.number(),
    borrowedUsd: v.number(),
    /** 0..100; `borrowedUsd / suppliedUsd`, stored to avoid recompute. */
    utilizationPct: v.number(),
    supplyApyPct: v.number(),
    borrowAprPct: v.number(),
    /** Pools: same as suppliedUsd. Assets: total reserve value. */
    tvlUsd: v.number(),
    /** Rolling 24h swap volume; 0 for single-asset markets. */
    volumeUsd: v.number(),
    feesUsd: v.number(),
    /** End-of-day spot price of the underlying (assets only). */
    priceUsd: v.optional(v.number()),
    supplyCapUsd: v.optional(v.number()),
    borrowCapUsd: v.optional(v.number()),
  }).index("by_market_day", ["marketId", "day"]),

  /** Borrow product daily stats (pool + asset), slug-keyed. */
  borrowDailyStats: defineTable({
    slug: v.string(),
    kind: v.union(v.literal("pool"), v.literal("asset")),
    day: v.string(),
    suppliedUsd: v.number(),
    borrowedUsd: v.number(),
    utilizationPct: v.number(),
    supplyApyPct: v.number(),
    borrowAprPct: v.number(),
    tvlUsd: v.number(),
    volumeUsd: v.number(),
    feesUsd: v.number(),
    priceUsd: v.optional(v.number()),
    supplyCapUsd: v.optional(v.number()),
    borrowCapUsd: v.optional(v.number()),
  }).index("by_slug_day", ["slug", "day"]),

  lendDailyStats: defineTable({
    slug: v.string(),
    day: v.string(),
    suppliedUsd: v.number(),
    borrowedUsd: v.number(),
    utilizationPct: v.number(),
    supplyApyPct: v.number(),
    borrowAprPct: v.number(),
    tvlUsd: v.number(),
    volumeUsd: v.number(),
    feesUsd: v.number(),
    priceUsd: v.optional(v.number()),
    supplyCapUsd: v.optional(v.number()),
    borrowCapUsd: v.optional(v.number()),
  }).index("by_slug_day", ["slug", "day"]),

  multiplyDailyStats: defineTable({
    slug: v.string(),
    day: v.string(),
    suppliedUsd: v.number(),
    borrowedUsd: v.number(),
    utilizationPct: v.number(),
    supplyApyPct: v.number(),
    borrowAprPct: v.number(),
    tvlUsd: v.number(),
    volumeUsd: v.number(),
    feesUsd: v.number(),
    priceUsd: v.optional(v.number()),
    supplyCapUsd: v.optional(v.number()),
    borrowCapUsd: v.optional(v.number()),
  }).index("by_slug_day", ["slug", "day"]),

  /**
   * Precomputed cache for `listMarketSnapshots`, which is subscribed app-wide — reading
   * one document keeps it O(1) instead of a full `markets` collect plus an indexed read
   * per market (~173) on every subscriber recompute. Rebuilt by
   * `rebuildMarketSnapshots` on write / on schedule.
   */
  marketSnapshotsCache: defineTable({
    /** Constant discriminator so there is exactly one cache row (`"markets"`). */
    singleton: v.string(),
    rows: v.array(
      v.object({
        slug: v.string(),
        scope: marketScope,
        name: v.string(),
        symbol: v.string(),
        chainId: v.number(),
        venueLabel: v.optional(v.string()),
        category: v.optional(v.union(v.literal("stable"), v.literal("crypto"), v.literal("stock"))),
        description: v.optional(v.string()),
        iconUrl: v.optional(v.string()),
        spokeId: v.optional(v.string()),
        feeTier: v.optional(v.string()),
        maxLtvPct: v.optional(v.number()),
        reserveFactorPct: v.optional(v.number()),
        rewardsApyPct: v.optional(v.number()),
        /** Latest siloed risk-assessment premium, bps. */
        premiumBps: v.optional(v.number()),
        visuals: v.optional(
          v.array(
            v.object({
              symbol: v.string(),
              shortLabel: v.string(),
              bgClassName: v.string(),
              textClassName: v.string(),
              iconUrl: v.optional(v.string()),
            }),
          ),
        ),
        resources: v.optional(v.array(v.object({ label: v.string(), href: v.string() }))),
        suppliedUsd: v.number(),
        borrowedUsd: v.number(),
        availableUsd: v.number(),
        utilizationPct: v.number(),
        supplyApyPct: v.number(),
        borrowAprPct: v.number(),
        tvlUsd: v.number(),
        volumeUsd: v.number(),
        feesUsd: v.number(),
      }),
    ),
    updatedAt: v.number(),
  }).index("by_singleton", ["singleton"]),

  /**
   * LEGACY shared daily revenue per market (Cashflow card). Prefer the siloed
   * `borrowRevenueDaily` / `lendRevenueDaily` / `multiplyRevenueDaily`; kept for
   * dual-read and the seed still dual-writes.
   */
  marketRevenueDaily: defineTable({
    marketId: v.id("markets"),
    day: v.string(),
    interestFromBorrowersUsd: v.number(),
    /** Net of the reserve take. */
    interestToSuppliersUsd: v.number(),
    reserveTakeUsd: v.number(),
    /** External incentives on top of native yield. */
    rewardsDistributedUsd: v.number(),
    /** Pools only. */
    swapFeesUsd: v.number(),
  }).index("by_market_day", ["marketId", "day"]),

  /** Borrow product daily revenue (pool + asset), slug-keyed. */
  borrowRevenueDaily: defineTable({
    slug: v.string(),
    kind: v.union(v.literal("pool"), v.literal("asset")),
    day: v.string(),
    interestFromBorrowersUsd: v.number(),
    interestToSuppliersUsd: v.number(),
    reserveTakeUsd: v.number(),
    rewardsDistributedUsd: v.number(),
    swapFeesUsd: v.number(),
  }).index("by_slug_day", ["slug", "day"]),

  lendRevenueDaily: defineTable({
    slug: v.string(),
    day: v.string(),
    interestFromBorrowersUsd: v.number(),
    interestToSuppliersUsd: v.number(),
    reserveTakeUsd: v.number(),
    rewardsDistributedUsd: v.number(),
    swapFeesUsd: v.number(),
  }).index("by_slug_day", ["slug", "day"]),

  multiplyRevenueDaily: defineTable({
    slug: v.string(),
    day: v.string(),
    interestFromBorrowersUsd: v.number(),
    interestToSuppliersUsd: v.number(),
    reserveTakeUsd: v.number(),
    rewardsDistributedUsd: v.number(),
    swapFeesUsd: v.number(),
  }).index("by_slug_day", ["slug", "day"]),

  /**
   * Daily split of an asset's liquidity across pools; drives `AssetDetail.allocation`.
   * Keyed by asset, with `poolId` joining back to `markets` for display.
   */
  assetPoolAllocationDaily: defineTable({
    assetId: v.id("markets"),
    poolId: v.id("markets"),
    day: v.string(),
    valueUsd: v.number(),
    /** 0..100, share of the asset's total deployed value. */
    sharePct: v.number(),
    utilizationPct: v.number(),
    borrowAprPct: v.number(),
  })
    .index("by_asset_day", ["assetId", "day"])
    .index("by_pool_day", ["poolId", "day"]),

  /**
   * LEGACY shared risk review snapshots (Risk Premium card). Prefer the siloed
   * `borrowRiskAssessments` / `lendRiskAssessments` / `multiplyRiskAssessments`; kept
   * for dual-read and the seed still dual-writes.
   */
  riskAssessments: defineTable({
    marketId: v.id("markets"),
    assessedAt: v.number(),
    premiumBps: v.number(),
    level: riskLevel,
    /** 0..100 gauge score. */
    score: v.number(),
    headline: v.string(),
    summary: v.string(),
    breakdown: v.array(
      v.object({
        id: v.string(),
        label: v.string(),
        bps: v.number(),
        level: riskLevel,
        description: v.string(),
      }),
    ),
    metrics: v.array(
      v.object({
        id: v.string(),
        label: v.string(),
        value: v.string(),
        hint: v.optional(v.string()),
      }),
    ),
  }).index("by_market_assessed_at", ["marketId", "assessedAt"]),

  /**
   * Shared multi-user liquidity ledger: every borrow / repay / supply / withdraw
   * APPENDS a row here, and `convex/liquidity.ts` folds them per market onto the base
   * catalog. APPEND-ONLY BY DESIGN — patching one per-market row put every writer on
   * the same document and made concurrent actions contend under Convex OCC.
   *
   * Growth is handled by compaction, never by patching: past a dirty threshold
   * `liquidity.compactDeltas` folds the oldest rows into `marketLiquidityBaseline` and
   * deletes them, so this table holds a bounded recent window. Every row is counted
   * exactly once — raw here until folded, then baseline only.
   */
  marketLiquidityDeltas: defineTable({
    /** Pool id ("uni-v3-bluechip-weth-usdc") or borrowable asset id ("uni-v2:usdc"). */
    marketSlug: v.string(),
    /** Net borrowed change in USD (borrow +, repay −). */
    borrowedDeltaUsd: v.number(),
    /** Net supplied/collateral change in USD (supply/deposit +, withdraw −). */
    suppliedDeltaUsd: v.number(),
    updatedAt: v.number(),
  }).index("by_slug", ["marketSlug"]),

  /**
   * Cumulative per-market fold of every COMPACTED `marketLiquidityDeltas` row, so the
   * live fold is `baseline + the few un-compacted deltas` rather than a full-table
   * scan. One row per market slug. Compaction only writes here, never on the hot
   * append path.
   */
  marketLiquidityBaseline: defineTable({
    marketSlug: v.string(),
    /** Running sums over the compacted rows for this market. */
    borrowedDeltaUsd: v.number(),
    suppliedDeltaUsd: v.number(),
    /** Max `updatedAt` of any delta folded in here. */
    updatedAt: v.number(),
  }).index("by_slug", ["marketSlug"]),

  /**
   * O(1) fold of `marketLiquidityDeltas` for the app-wide `liquidity.listDeltaSnapshot`
   * subscription. READ BY EVERY AUTHENTICATED CLIENT, so any write re-runs those
   * subscriptions everywhere: rebuilds MUST stay coalesced behind `liquidityRebuildState`
   * (`liquidity.SNAPSHOT_REBUILD_DEBOUNCE_MS`) and never be written inline per append, or
   * the fan-out scales with writes × concurrent sessions. Eventually consistent within
   * one debounce window.
   */
  liquidityDeltasCache: defineTable({
    /** Constant discriminator so there is exactly one cache row (`"deltas"`). */
    singleton: v.string(),
    rows: v.array(
      v.object({
        marketSlug: v.string(),
        borrowedDeltaUsd: v.number(),
        suppliedDeltaUsd: v.number(),
        updatedAt: v.number(),
      }),
    ),
    updatedAt: v.number(),
  }).index("by_singleton", ["singleton"]),

  /**
   * Debounce marker for `liquidityDeltasCache` rebuilds. Must stay a SEPARATE table no
   * client subscription reads, so bumping it on a hot append invalidates nobody.
   */
  liquidityRebuildState: defineTable({
    /** Constant discriminator so there is exactly one state row (`"deltas"`). */
    singleton: v.string(),
    /** ms epoch the queued rebuild will run; 0 = none pending. */
    scheduledFor: v.number(),
  }).index("by_singleton", ["singleton"]),

  /**
   * Sharded economy counters. Every claim read-and-patched the single `sandboxEconomy`
   * row, so concurrent claims contended under Convex OCC (~53% failed). A claim now
   * adds its grant to one randomly-chosen shard; the live count/total is the sum of all
   * shards, so the aggregate stays exact with no hot document.
   */
  sandboxEconomyShards: defineTable({
    /** 0..N-1 shard bucket; a claim picks one at random to increment. */
    shard: v.number(),
    userCount: v.number(),
    grantedUsd: v.number(),
  }).index("by_shard", ["shard"]),

  /**
   * Real token spot prices — the ONE place the sandbox reads live market data
   * (`convex/prices.ts refreshPrices`, from DefiLlama). Supply/borrow/TVL stay
   * simulated. One row per lowercase base symbol.
   */
  tokenPrices: defineTable({
    /** Lowercase base symbol, e.g. "usdc". Matches SpokeBorrowableRecord.baseAssetId. */
    symbol: v.string(),
    /** DefiLlama coin id (chain:address or coingecko:id). */
    llamaId: v.string(),
    /**
     * Prefer (chainId, contractAddress) over symbol for identity — two tokens on
     * different chains can share a symbol. Absent for coingecko-id quotes (e.g. native
     * ETH), which carry no contract.
     */
    chainId: v.optional(v.number()),
    contractAddress: v.optional(v.string()),
    priceUsd: v.number(),
    decimals: v.optional(v.number()),
    /** DefiLlama price confidence (0..1). */
    confidence: v.optional(v.number()),
    /**
     * Freshness lineage: sourceUpdatedAt = provider's own quote time, fetchedAt = when the
     * response arrived, snapshotAt = when the row was written. A failed refresh writes
     * nothing, so none of these ever advance on stale data. `status` is the classification
     * at write time; the client re-derives live age as well.
     */
    sourceUpdatedAt: v.optional(v.number()),
    fetchedAt: v.optional(v.number()),
    snapshotAt: v.optional(v.number()),
    status: v.optional(v.union(v.literal("fresh"), v.literal("stale"), v.literal("invalid"))),
    /**
     * "defillama" = hourly live spot; "baseline" = seeded snapshot used until the first
     * live refresh. A live upsert always overwrites a baseline on the same symbol.
     */
    source: v.string(),
    /**
     * 24h price change as a 1e18 wad (bigint stored as a string). Absent when DefiLlama
     * omits percentChange1d, and the UI then suppresses the delta arrow.
     */
    priceChange24hWad: v.optional(v.string()),
    updatedAt: v.number(),
  })
    .index("by_symbol", ["symbol"])
    .index("by_chain_contract", ["chainId", "contractAddress"]),

  /**
   * Last successful oracle/FX provider check. Written on every successful refresh even
   * when the quotes are unchanged, so freshness is observable without rewriting quote
   * rows — which would invalidate every price subscriber.
   */
  oracleProviderHealth: defineTable({
    kind: v.union(v.literal("prices"), v.literal("fx")),
    checkedAt: v.number(),
    sourceUpdatedAt: v.optional(v.number()),
    quoteCount: v.number(),
    written: v.number(),
    unchanged: v.number(),
  }).index("by_kind", ["kind"]),

  /**
   * Daily closing token prices, one row per (symbol, UTC day). Deliberately SEPARATE from
   * `tokenPrices`: the UI reads `tokenPrices`, charts read this, so an old value can never
   * be mistaken for the live price.
   */
  tokenPricesHistory: defineTable({
    symbol: v.string(),
    day: v.string(),
    priceUsd: v.number(),
    updatedAt: v.number(),
  }).index("by_symbol_day", ["symbol", "day"]),

  /**
   * Fiat FX rates, refreshed server-side from open.er-api.com so conversion never depends
   * on client polling. `usdPerUnit` = units of the currency per 1 USD (USD row is always 1).
   * Same freshness lineage as tokenPrices; a failed refresh writes nothing.
   */
  fxRates: defineTable({
    currency: v.string(),
    usdPerUnit: v.number(),
    source: v.string(),
    status: v.optional(v.union(v.literal("fresh"), v.literal("stale"), v.literal("invalid"))),
    sourceUpdatedAt: v.optional(v.number()),
    fetchedAt: v.optional(v.number()),
    updatedAt: v.number(),
  }).index("by_currency", ["currency"]),

  /**
   * LEGACY shared editorial content (About / history / FAQs). Prefer the siloed
   * `borrowMarketContent` / `lendMarketContent` / `multiplyMarketContent`; kept for
   * dual-read and the seed still dual-writes.
   */
  marketContent: defineTable({
    marketId: v.id("markets"),
    description: v.string(),
    stats: v.array(v.object({ label: v.string(), value: v.string(), href: v.optional(v.string()) })),
    history: v.array(v.object({ date: v.string(), title: v.string(), description: v.optional(v.string()) })),
    faqs: v.array(v.object({ question: v.string(), answer: v.string() })),
  }).index("by_market", ["marketId"]),

  // Product-siloed detail params, keyed by product slug — never share rows across products.

  /** Borrow About / FAQs / parameter-change history (pool + asset). */
  borrowMarketContent: defineTable({
    slug: v.string(),
    kind: v.union(v.literal("pool"), v.literal("asset")),
    description: v.string(),
    stats: v.array(v.object({ label: v.string(), value: v.string(), href: v.optional(v.string()) })),
    history: v.array(v.object({ date: v.string(), title: v.string(), description: v.optional(v.string()) })),
    faqs: v.array(v.object({ question: v.string(), answer: v.string() })),
  }).index("by_slug", ["slug"]),

  /** Borrow Risk Premium / assessment card (pool + asset). Distinct from `borrowRiskParameters`. */
  borrowRiskAssessments: defineTable({
    slug: v.string(),
    kind: v.union(v.literal("pool"), v.literal("asset")),
    assessedAt: v.number(),
    premiumBps: v.number(),
    level: riskLevel,
    score: v.number(),
    headline: v.string(),
    summary: v.string(),
    breakdown: v.array(
      v.object({
        id: v.string(),
        label: v.string(),
        bps: v.number(),
        level: riskLevel,
        description: v.string(),
      }),
    ),
    metrics: v.array(
      v.object({
        id: v.string(),
        label: v.string(),
        value: v.string(),
        hint: v.optional(v.string()),
      }),
    ),
  }).index("by_slug", ["slug"]),

  /** Borrow Risk Parameters grid (pool + asset). One latest row per slug. */
  borrowRiskParameters: defineTable({
    slug: v.string(),
    kind: v.union(v.literal("pool"), v.literal("asset")),
    parameters: v.array(
      v.object({
        id: v.string(),
        label: v.string(),
        value: v.string(),
        description: v.optional(v.string()),
      }),
    ),
    updatedAt: v.number(),
    source: v.optional(v.union(v.literal("seed"), v.literal("chain"))),
    txHash: v.optional(v.string()),
  }).index("by_slug", ["slug"]),

  /** Borrow Interest Rate Model curve params (asset markets). */
  borrowInterestRateModels: defineTable({
    slug: v.string(),
    optimalUtilizationPct: v.number(),
    slopeBelowOptimalPct: v.number(),
    slopeAboveOptimalPct: v.number(),
    baseBorrowRatePct: v.number(),
    updatedAt: v.number(),
    source: v.optional(v.union(v.literal("seed"), v.literal("chain"))),
    txHash: v.optional(v.string()),
  }).index("by_slug", ["slug"]),

  /** Borrow market liquidation KPIs (pool markets), one row per pool per day. */
  borrowLiquidationDaily: defineTable({
    slug: v.string(),
    day: v.string(),
    liquidationsCount: v.number(),
    collateralSeizedUsd: v.number(),
    debtRepaidUsd: v.number(),
    liquidationBonusUsd: v.number(),
    collateralAtRiskUsd: v.number(),
    walletsAtRisk: v.number(),
    walletsEligibleForLiquidation: v.number(),
    badDebtUsd: v.number(),
    walletsWithBadDebt: v.number(),
  }).index("by_slug_day", ["slug", "day"]),

  /** Borrow pool → borrowable asset edges (Assets You Can Borrow). */
  borrowPoolBorrowables: defineTable({
    poolSlug: v.string(),
    assetSlug: v.string(),
    name: v.string(),
    symbol: v.string(),
    borrowAprPct: v.number(),
  }).index("by_pool", ["poolSlug"]),

  /** Lend About / FAQs / parameter-change history. */
  lendMarketContent: defineTable({
    slug: v.string(),
    description: v.string(),
    stats: v.array(v.object({ label: v.string(), value: v.string(), href: v.optional(v.string()) })),
    history: v.array(v.object({ date: v.string(), title: v.string(), description: v.optional(v.string()) })),
    faqs: v.array(v.object({ question: v.string(), answer: v.string() })),
  }).index("by_slug", ["slug"]),

  /** Lend Risk Premium / assessment card. Distinct from `lendRiskParameters`. */
  lendRiskAssessments: defineTable({
    slug: v.string(),
    assessedAt: v.number(),
    premiumBps: v.number(),
    level: riskLevel,
    score: v.number(),
    headline: v.string(),
    summary: v.string(),
    breakdown: v.array(
      v.object({
        id: v.string(),
        label: v.string(),
        bps: v.number(),
        level: riskLevel,
        description: v.string(),
      }),
    ),
    metrics: v.array(
      v.object({
        id: v.string(),
        label: v.string(),
        value: v.string(),
        hint: v.optional(v.string()),
      }),
    ),
  }).index("by_slug", ["slug"]),

  lendRiskParameters: defineTable({
    slug: v.string(),
    parameters: v.array(
      v.object({
        id: v.string(),
        label: v.string(),
        value: v.string(),
        description: v.optional(v.string()),
      }),
    ),
    updatedAt: v.number(),
    source: v.optional(v.union(v.literal("seed"), v.literal("chain"))),
    txHash: v.optional(v.string()),
  }).index("by_slug", ["slug"]),

  lendInterestRateModels: defineTable({
    slug: v.string(),
    optimalUtilizationPct: v.number(),
    slopeBelowOptimalPct: v.number(),
    slopeAboveOptimalPct: v.number(),
    baseBorrowRatePct: v.number(),
    updatedAt: v.number(),
    source: v.optional(v.union(v.literal("seed"), v.literal("chain"))),
    txHash: v.optional(v.string()),
  }).index("by_slug", ["slug"]),

  /** Multiply About / FAQs / parameter-change history. */
  multiplyMarketContent: defineTable({
    slug: v.string(),
    description: v.string(),
    stats: v.array(v.object({ label: v.string(), value: v.string(), href: v.optional(v.string()) })),
    history: v.array(v.object({ date: v.string(), title: v.string(), description: v.optional(v.string()) })),
    faqs: v.array(v.object({ question: v.string(), answer: v.string() })),
  }).index("by_slug", ["slug"]),

  /**
   * Governance "Parameter changelog": one doc per market holding parameter transitions
   * (previous → current), newest first. Richer than the `*MarketContent.history`
   * timeline — carries source/executor/category. Borrow pool + asset share the
   * `"borrow"` product with disjoint slugs.
   */
  parameterChanges: defineTable({
    product: v.union(v.literal("borrow"), v.literal("lend"), v.literal("multiply")),
    slug: v.string(),
    changes: v.array(
      v.object({
        id: v.string(),
        parameter: v.string(),
        previous: v.string(),
        current: v.string(),
        date: v.string(),
        source: v.string(),
        executor: v.string(),
        category: v.string(),
        href: v.optional(v.string()),
      }),
    ),
    updatedAt: v.number(),
  }).index("by_market", ["product", "slug"]),

  /** Multiply Risk Premium / assessment card. Distinct from `multiplyRiskParameters`. */
  multiplyRiskAssessments: defineTable({
    slug: v.string(),
    assessedAt: v.number(),
    premiumBps: v.number(),
    level: riskLevel,
    score: v.number(),
    headline: v.string(),
    summary: v.string(),
    breakdown: v.array(
      v.object({
        id: v.string(),
        label: v.string(),
        bps: v.number(),
        level: riskLevel,
        description: v.string(),
      }),
    ),
    metrics: v.array(
      v.object({
        id: v.string(),
        label: v.string(),
        value: v.string(),
        hint: v.optional(v.string()),
      }),
    ),
  }).index("by_slug", ["slug"]),

  multiplyRiskParameters: defineTable({
    slug: v.string(),
    parameters: v.array(
      v.object({
        id: v.string(),
        label: v.string(),
        value: v.string(),
        description: v.optional(v.string()),
      }),
    ),
    updatedAt: v.number(),
    source: v.optional(v.union(v.literal("seed"), v.literal("chain"))),
    txHash: v.optional(v.string()),
  }).index("by_slug", ["slug"]),

  /** Multiply market liquidation KPIs, one row per market per day. */
  multiplyLiquidationDaily: defineTable({
    slug: v.string(),
    day: v.string(),
    liquidationsCount: v.number(),
    collateralSeizedUsd: v.number(),
    debtRepaidUsd: v.number(),
    liquidationBonusUsd: v.number(),
    collateralAtRiskUsd: v.number(),
    walletsAtRisk: v.number(),
    walletsEligibleForLiquidation: v.number(),
    badDebtUsd: v.number(),
    walletsWithBadDebt: v.number(),
  }).index("by_slug_day", ["slug", "day"]),

  /**
   * Support Center submissions. Wallet/email are optional because the sender may not be
   * signed in; status starts at "new".
   */
  supportRequests: defineTable({
    wallet: v.optional(v.string()),
    userEmail: v.optional(v.string()),
    category: v.string(),
    categoryLabel: v.optional(v.string()),
    topic: v.string(),
    topicLabel: v.optional(v.string()),
    message: v.string(),
    status: v.union(v.literal("new"), v.literal("in_progress"), v.literal("resolved")),
    userAgent: v.optional(v.string()),
    createdAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_wallet_created", ["wallet", "createdAt"])
    .index("by_status", ["status"])
    .index("by_created_at", ["createdAt"]),

  // Wallet-scoped sandbox state — synthetic, never source of truth in prod.

  /**
   * Single authoritative row holding the global sandbox economy caps. Caps are enforced
   * SERVER-SIDE at claim time and never trusted from the client.
   */
  sandboxEconomy: defineTable({
    userCap: v.number(),
    totalGrantedUsdCap: v.number(),
    perUserTargetUsd: v.number(),
    minMultiplier: v.number(),
    maxMultiplier: v.number(),
    userCount: v.number(),
    totalGrantedUsd: v.number(),
    status: v.union(v.literal("open"), v.literal("closed")),
    closedReason: v.optional(v.string()),
    closedAt: v.optional(v.number()),
  }),

  /** Single tunable row: allocation basket weights + onboarding copy/links. */
  sandboxConfig: defineTable({
    basket: v.array(v.object({ tokenId: v.string(), weight: v.number() })),
    seedVersion: v.number(),
    tweetTemplate: v.optional(v.string()),
    xHandle: v.optional(v.string()),
    resourcesLinks: v.optional(v.array(v.object({ label: v.string(), href: v.string() }))),
  }),

  /** Minimal immutable starter catalog read by every onboarding claim in one indexed lookup. */
  sandboxStarterCatalog: defineTable({
    singleton: v.string(),
    rows: v.array(
      v.object({
        slug: v.string(),
        scope: marketScope,
        symbol: v.string(),
        priceUsd: v.number(),
      }),
    ),
    updatedAt: v.number(),
    /** Grant-manifest version; a mismatch with STARTER_CATALOG_VERSION rebuilds the cache
     *  so newly seeded markets become grantable. */
    version: v.optional(v.number()),
  }).index("by_singleton", ["singleton"]),

  /** Per-authenticated-user onboarding + allocation profile. */
  sandboxProfiles: defineTable({
    /** Lowercased wallet address; MUST match the authenticated identity. */
    wallet: v.string(),
    /** @deprecated Migration-only. New identity data belongs in walletProfiles. */
    authSubject: v.optional(v.string()),
    createdAt: v.number(),
    seedVersion: v.number(),
    onboardingStep: v.union(
      v.literal("wallet"),
      v.literal("analyzing"),
      v.literal("eligible"),
      v.literal("xPending"),
      v.literal("xConfirmed"),
      v.literal("claimPending"),
      v.literal("done"),
      v.literal("waitlisted"),
    ),
    onboardedAt: v.optional(v.number()),
    eligibilityTier: v.optional(v.number()),
    tierSeed: v.optional(v.string()),
    allocatedUsd: v.optional(v.number()),
    basketSnapshot: v.optional(
      v.array(v.object({ tokenId: v.string(), amount: v.number(), priceUsdAtClaim: v.number() })),
    ),
    xHandle: v.optional(v.string()),
    tweetUrl: v.optional(v.string()),
    tweetedAt: v.optional(v.number()),
    claimTxSynthetic: v.optional(v.string()),
    /** @deprecated Migration-only. New preferences belong in walletProfiles. */
    preferences: v.optional(
      v.object({
        theme: v.optional(v.string()),
        language: v.optional(v.string()),
        currency: v.optional(v.string()),
        showDollarAmounts: v.optional(v.boolean()),
        /** Short display name captured at onboarding (≤10 chars). */
        name: v.optional(v.string()),
        dexSources: v.optional(v.array(v.string())),
      }),
    ),
  })
    .index("by_wallet", ["wallet"])
    .index("by_authSubject", ["authSubject"]),

  /** Permanent wallet identity and display preferences, independent of Sandbox onboarding. */
  walletProfiles: defineTable({
    /** Lowercased, derived from the authenticated identity. */
    wallet: v.string(),
    /** Privy user id or SIWE-JWT subject. */
    authSubject: v.optional(v.string()),
    preferences: v.optional(
      v.object({
        theme: v.optional(v.string()),
        language: v.optional(v.string()),
        currency: v.optional(v.string()),
        showDollarAmounts: v.optional(v.boolean()),
        name: v.optional(v.string()),
        dexSources: v.optional(v.array(v.string())),
      }),
    ),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_authSubject", ["authSubject"]),

  /** Immutable, idempotent manifest of the wallet's diversified $1M starter grant. */
  starterAllocations: defineTable({
    wallet: v.string(),
    version: v.number(),
    totalEquityUsd: v.number(),
    liquid: v.array(v.object({ marketSlug: v.string(), amountUsd: v.number() })),
    collateral: v.array(v.object({ marketSlug: v.string(), amountUsd: v.number() })),
    lend: v.array(v.object({ marketSlug: v.string(), amountUsd: v.number() })),
    multiply: v.array(v.object({ marketSlug: v.string(), amountUsd: v.number() })),
    receiptHashes: v.array(v.string()),
    createdAt: v.number(),
  }).index("by_wallet", ["wallet"]),

  /** Wallet-scoped sandbox activity log (one row per balance-changing action). */
  sandboxActivity: defineTable({
    wallet: v.string(),
    kind: v.string(),
    amountUsd: v.number(),
    marketSlug: v.optional(v.string()),
    syntheticTxHash: v.string(),
    at: v.number(),
  })
    .index("by_wallet_at", ["wallet", "at"])
    .index("by_wallet_hash", ["wallet", "syntheticTxHash"]),

  /** Wallet-scoped rewards engine state for reactive sandbox rehydration. */
  sandboxRewards: defineTable({
    wallet: v.string(),
    stateJson: v.string(),
    updatedAt: v.number(),
    /** Optimistic-concurrency version; clients echo `expectedRevision` on update. */
    revision: v.optional(v.number()),
  }).index("by_wallet", ["wallet"]),

  /**
   * Shared per-key rate-limit buckets for the Next API route guards (SIWE nonce/verify/
   * dev-token). Must live here, not in process memory, so a horizontally-scaled deploy
   * enforces ONE limit across instances. `resetAt` = epoch ms the window ends.
   */
  rateLimitBuckets: defineTable({
    key: v.string(),
    count: v.number(),
    resetAt: v.number(),
  }).index("by_key", ["key"]),

  /**
   * Per-wallet remaining claimable on each borrow LP-fee reward position.
   * `remainingUsd6` is what is left AFTER the wallet's claims (decimal usd6 string), so
   * hydration reduces the seeded claimable instead of resetting it to full on reload. A
   * wallet with no row keeps the seeded (full) claimable.
   */
  sandboxRewardClaims: defineTable({
    wallet: v.string(),
    rewardPositionId: v.string(),
    remainingUsd6: v.string(),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_wallet_position", ["wallet", "rewardPositionId"]),

  // Wallet-scoped FINANCIAL state — synthetic, never prod truth.
  //
  // ENCODING CONTRACT: the credit/multiply engines use bigint fixed-point — usd6 (1e6),
  // WAD (1e18), RAY (1e27). Convex has no bigint and RAY overflows Number's safe-integer
  // range, so every fixed-point field below is a DECIMAL INTEGER STRING ("12400000000" =
  // 12,400 usd6), never a float. Nullable rates (e.g. an infinite health factor) are
  // `v.union(<string>, v.null())`. Plain-number fields belong ONLY to the multiply
  // engine, which is number-native.
  //
  // `wallet` is always the lowercased authed address, derived from ctx.auth server-side
  // (convex/sandbox/auth.ts); a client-passed wallet is never trusted.

  /**
   * Global (not wallet-scoped) LP collateral-pool catalog — the pledgeable LP-pair
   * catalog a `positionCollateral` row pledges into, mirroring `PortfolioPoolRecord`.
   * Distinct from `markets`, which is the borrow/lend/multiply market catalog.
   */
  pools: defineTable({
    /** URL-safe pool id, e.g. "uni-v3-bluechip-weth-usdc". */
    slug: v.string(),
    name: v.string(),
    venue: v.string(),
    /** e.g. "v3" | "stable" | "volatile". */
    category: v.string(),
    chainId: v.optional(v.number()),
    /** Exactly two legs (PortfolioPoolRecord.visuals tuple). */
    visuals: v.array(
      v.object({
        symbol: v.string(),
        shortLabel: v.string(),
        bgClassName: v.string(),
        textClassName: v.string(),
        iconUrl: v.optional(v.string()),
      }),
    ),
    maxLtvPct: v.number(),
    liquidationThresholdPct: v.optional(v.number()),
    pairAprPct: v.number(),
    lpTokenPriceUsd: v.optional(v.number()),
    /** Optional so existing pool rows migrate lazily; set by the borrow-catalog seed writer. */
    venueLabel: v.optional(v.string()),
    spokeId: v.optional(v.string()),
    dexId: v.optional(v.string()),
    feeTier: v.optional(v.string()),
    chain: v.optional(v.string()),
    subtitle: v.optional(v.string()),
    lpSymbol: v.optional(v.string()),
    collateralExampleUsd: v.optional(v.number()),
    riskPremiumBps: v.optional(v.number()),
    borrowableTokens: v.optional(
      v.array(
        v.object({
          symbol: v.string(),
          iconUrl: v.string(),
          shortLabel: v.string(),
          bgClass: v.string(),
          textClass: v.string(),
        }),
      ),
    ),
    supportedBorrowAssetIds: v.optional(v.array(v.string())),
    poolSeedName: v.optional(v.string()),
    createdAt: v.number(),
  })
    .index("by_slug", ["slug"])
    .index("by_spoke_id", ["spokeId"]),

  /**
   * Open/closed position, one row per (wallet, product, market). Borrow & lend carry
   * usd6 STRING fields; multiply is number-native (mirrors `MultiplyPosition`, incl. the
   * "infinity" health-factor sentinel and nullable liquidationPrice). Child
   * collateral/debt detail lives in `positionCollateral` / `positionDebt`.
   */
  positions: defineTable({
    wallet: v.string(),
    product: v.union(v.literal("borrow"), v.literal("multiply"), v.literal("lend"), v.literal("umbrella")),
    /** Joins to `markets.slug` or `pools.slug`. */
    marketSlug: v.string(),
    spokeId: v.optional(v.string()),
    assetId: v.optional(v.string()),
    status: v.union(v.literal("open"), v.literal("closed")),
    // borrow/lend (usd6 decimal strings)
    collateralValueUsd6: v.optional(v.string()),
    debtValueUsd6: v.optional(v.string()),
    suppliedUsd6: v.optional(v.string()),
    earnedUsd6: v.optional(v.string()),
    supplyApyPct: v.optional(v.number()),
    // Umbrella-only (optional so the shared table still fits borrow/lend/multiply rows).
    // `umbrellaCooldownTranches` is the per-tranche source of truth; these are the
    // DERIVED aggregate rollup over active tranches, recomputed after every tranche
    // mutation (startCooldown / unstake / simulateSlash), so one-number callers still work:
    //   cooldownAmountUsd6 = sum(amountUsd6); the three timestamps = min() across tranches.
    cooldownAmountUsd6: v.optional(v.string()),
    cooldownStartedAt: v.optional(v.number()),
    cooldownEndsAt: v.optional(v.number()),
    withdrawalWindowEndsAt: v.optional(v.number()),
    claimedRewardsUsd6: v.optional(v.string()),
    /** Umbrella-only: cumulative principal removed by simulated slashes; absent = 0. */
    slashedAmountUsd6: v.optional(v.string()),
    /**
     * Umbrella reward-accrual checkpoint. MUST stay distinct from `lastUpdatedAt`, which
     * every balance-sync patch touches — sharing it would reset accrued rewards. Moves
     * only when stake / claim / startCooldown / unstake re-checkpoints `earnedUsd6`.
     */
    rewardCheckpointAt: v.optional(v.number()),
    // multiply (number-native — see app/lib/multiply-engine/types.ts MultiplyPosition)
    collateralAmount: v.optional(v.number()),
    collateralValueUsd: v.optional(v.number()),
    debtValueUsd: v.optional(v.number()),
    multiplier: v.optional(v.number()),
    ltv: v.optional(v.number()),
    healthFactor: v.optional(v.union(v.number(), v.literal("infinity"))),
    liquidationPrice: v.optional(v.union(v.number(), v.null())),
    netApyPct: v.optional(v.number()),
    openedAt: v.number(),
    lastUpdatedAt: v.number(),
    closedAt: v.optional(v.number()),
    openTxSynthetic: v.optional(v.string()),
    /**
     * Optimistic-concurrency version, bumped on every successful write. A client that
     * computed from revision N sends `expectedRevision: N` and the server rejects the
     * write if the row has since advanced, instead of clobbering another tab's write.
     */
    revision: v.optional(v.number()),
  })
    .index("by_wallet", ["wallet"])
    .index("by_wallet_product", ["wallet", "product"])
    .index("by_wallet_market", ["wallet", "marketSlug"])
    // Cross-wallet aggregate scans: umbrella market-level Coverage / Amount-in-cooldown.
    .index("by_product_market", ["product", "marketSlug"])
    // Lets the position upsert be a `.unique()` instead of collect()+find().
    .index("by_wallet_product_market", ["wallet", "product", "marketSlug"]),

  /** Collateral leg of a borrow position. Mirrors `UserCollateralPosition`. */
  positionCollateral: defineTable({
    wallet: v.string(),
    positionId: v.id("positions"),
    /** Joins to `pools.slug`. */
    marketSlug: v.string(),
    collateralShares: v.string(),
    principalTokenAmount: v.string(),
    collateralEnabled: v.boolean(),
    /** Denormalized for O(1) reads. */
    collateralValueUsd6: v.optional(v.string()),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_position", ["positionId"]),

  /** Debt leg of a borrow position. Mirrors `UserDebtPosition` (share/index accounting). */
  positionDebt: defineTable({
    wallet: v.string(),
    positionId: v.id("positions"),
    assetId: v.string(),
    baseAssetId: v.string(),
    spokeId: v.optional(v.string()),
    marketSlug: v.optional(v.string()),
    debtSharesUsd6: v.string(),
    debtIndexRay: v.string(),
    borrowRateWad: v.string(),
    principalBorrowedUsd6: v.string(),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_position", ["positionId"]),

  /**
   * Per-wallet transaction ledger — INVARIANT: exactly one row per balance-changing
   * action. IDEMPOTENCY: the execute mutation looks up the client `intentId` via
   * `by_wallet_intent`, so replays and double clicks return the existing row.
   * `amountUsd` is denormalized human USD so activity feeds read without decoding usd6.
   * `sandboxActivity` stays the onboarding-claim log; portfolio activity merges both.
   */
  transactions: defineTable({
    wallet: v.string(),
    intentId: v.optional(v.string()),
    product: v.union(
      v.literal("borrow"),
      v.literal("lend"),
      v.literal("multiply"),
      v.literal("swap"),
      v.literal("rewards"),
      v.literal("umbrella"),
    ),
    /** deposit | withdraw | borrow | repay | claim | liquidate | multiply | deleverage | swap */
    kind: v.string(),
    status: v.union(v.literal("success"), v.literal("failed"), v.literal("pending")),
    marketSlug: v.optional(v.string()),
    assetId: v.optional(v.string()),
    positionId: v.optional(v.id("positions")),
    requestedAmountUsd6: v.string(),
    executedAmountUsd6: v.string(),
    amountUsd: v.number(),
    healthFactorWadBefore: v.optional(v.union(v.string(), v.null())),
    healthFactorWadAfter: v.optional(v.union(v.string(), v.null())),
    /** Leverage at the time of THIS transaction. Hydrated history must read these, not the
     *  position's current multiplier, or deleverages render as leverage increases. */
    multiplierBefore: v.optional(v.number()),
    multiplierAfter: v.optional(v.number()),
    /** Lend deposit/withdraw: tokens moved, priced at the oracle when written, so history does not
     *  re-derive the quantity from USD at today's price (an AAVE withdraw read 0.864, 1.14, 0.868). */
    tokenAmount: v.optional(v.number()),
    /** Swap-only: token identity + amounts, so the activity feed renders
     *  "0.001 ETH → 1.925 USDC" from the durable row alone. */
    swapInputSymbol: v.optional(v.string()),
    swapOutputSymbol: v.optional(v.string()),
    swapInputAmount: v.optional(v.number()),
    swapOutputAmount: v.optional(v.number()),
    /** Swap-only receipt detail: quote/provider/economics, so the receipt renders the full
     *  breakdown from the durable row alone — cross-device, or after in-session swap
     *  history is gone. */
    swapProvider: v.optional(v.string()),
    swapQuoteId: v.optional(v.string()),
    swapNetworkFeeUsd: v.optional(v.number()),
    swapMinOutputAmount: v.optional(v.number()),
    swapPriceImpactPct: v.optional(v.number()),
    swapSlippageBps: v.optional(v.number()),
    /** Rewards-only: the quest ids this claim paid out. `recordRewardsClaim` writes them so
     *  it can reject a later re-claim server-side, rather than trusting the client to
     *  filter its own state blob. */
    claimedTaskIds: v.optional(v.array(v.string())),
    syntheticTxHash: v.string(),
    simulated: v.boolean(),
    at: v.number(),
  })
    .index("by_wallet_at", ["wallet", "at"])
    .index("by_wallet_intent", ["wallet", "intentId"])
    .index("by_wallet_hash", ["wallet", "syntheticTxHash"])
    .index("by_market_at", ["marketSlug", "at"])
    .index("by_asset_at", ["assetId", "at"])
    .index("by_wallet_product_at", ["wallet", "product", "at"]),

  /**
   * Append-only risk/health history per wallet. Health MUST stay SPOKE-scoped rather than
   * collapsed to one account health factor — `calculateSpokeCreditMetrics` is per-spoke.
   * Latest row = current risk; the history feeds the hero risk chart.
   */
  riskSnapshots: defineTable({
    wallet: v.string(),
    at: v.number(),
    collateralValueUsd6: v.string(),
    borrowCapacityUsd6: v.string(),
    availableBorrowCapacityUsd6: v.string(),
    totalBorrowedUsd6: v.string(),
    currentLtvWad: v.string(),
    healthFactorWad: v.union(v.string(), v.null()),
    spokes: v.array(
      v.object({
        spokeId: v.string(),
        availableCreditUsd6: v.string(),
        totalBorrowedUsd6: v.string(),
        liquidationBufferUsd6: v.string(),
        healthFactorWad: v.union(v.string(), v.null()),
      }),
    ),
    /** Action kind that produced this snapshot (e.g. "borrow"). */
    trigger: v.optional(v.string()),
  }).index("by_wallet_at", ["wallet", "at"]),

  /**
   * Audit log of liquidation PREVIEWS — analytics only; sandbox liquidation never
   * executes. `wallet` is the position owner (victim).
   */
  liquidationPreviews: defineTable({
    wallet: v.string(),
    positionId: v.optional(v.id("positions")),
    marketSlug: v.optional(v.string()),
    repayAmountUsd6: v.string(),
    seizeCollateralUsd6: v.string(),
    healthFactorWadBefore: v.union(v.string(), v.null()),
    healthFactorWadAfter: v.union(v.string(), v.null()),
    liquidationBonusBps: v.optional(v.number()),
    allowed: v.boolean(),
    reason: v.optional(v.string()),
    at: v.number(),
  }).index("by_wallet_at", ["wallet", "at"]),

  /**
   * Recorded liquidation ACTIONS. `wallet` is the victim (wallet-scoped read),
   * `liquidatorWallet` the keeper; indexed both ways so either party can list its own.
   */
  liquidationActions: defineTable({
    wallet: v.string(),
    liquidatorWallet: v.string(),
    intentId: v.optional(v.string()),
    positionId: v.optional(v.id("positions")),
    debtPositionId: v.optional(v.id("positionDebt")),
    marketSlug: v.optional(v.string()),
    repaidUsd6: v.string(),
    seizedCollateralUsd6: v.string(),
    liquidationBonusBps: v.optional(v.number()),
    healthFactorWadBefore: v.union(v.string(), v.null()),
    healthFactorWadAfter: v.union(v.string(), v.null()),
    syntheticTxHash: v.string(),
    at: v.number(),
  })
    .index("by_wallet_at", ["wallet", "at"])
    .index("by_liquidator_at", ["liquidatorWallet", "at"])
    .index("by_liquidator_intent", ["liquidatorWallet", "intentId"]),

  /**
   * Append-only portfolio time series per wallet (mirrors `PortfolioSnapshotRecord`),
   * feeding the hero chart. `at` is ms-epoch; values are plain-number USD.
   */
  portfolioSnapshots: defineTable({
    wallet: v.string(),
    at: v.number(),
    totalValueUsd: v.number(),
    totalSuppliedUsd: v.number(),
    totalBorrowedUsd: v.number(),
    availableToBorrowUsd: v.number(),
    totalMultiplyExposureUsd: v.number(),
    totalEarnedUsd: v.number(),
  }).index("by_wallet_at", ["wallet", "at"]),

  /** One mutable current portfolio row per wallet; hot dashboard reads never scan history. */
  portfolioCurrent: defineTable({
    wallet: v.string(),
    at: v.number(),
    totalValueUsd: v.number(),
    totalSuppliedUsd: v.number(),
    totalBorrowedUsd: v.number(),
    availableToBorrowUsd: v.number(),
    totalMultiplyExposureUsd: v.number(),
    totalEarnedUsd: v.number(),
  }).index("by_wallet", ["wallet"]),

  /** Wallet-scoped seed/session metadata and idempotency flags. */
  walletSessions: defineTable({
    wallet: v.string(),
    authSubject: v.optional(v.string()),
    seedVersion: v.number(),
    seededAt: v.optional(v.number()),
    lastSeenAt: v.number(),
    umbrellaSeeded: v.optional(v.boolean()),
  }).index("by_wallet", ["wallet"]),

  /**
   * Live per-market umbrella state that mutates outside the frozen catalog. Source of
   * truth once `simulateDeficit` / `simulateSlash` populates it; the UMBRELLA_MARKETS
   * constant in `convex/sandbox/umbrella.ts` is the fallback.
   */
  umbrellaMarketState: defineTable({
    marketId: v.string(),
    currentDeficitUsd: v.number(),
    deficitOffsetUsd: v.number(),
    totalSlashedUsd: v.number(),
    updatedAt: v.number(),
  }).index("by_market", ["marketId"]),

  /**
   * Running Σ suppliedUsd6 / cooldownAmountUsd6 over every wallet's umbrella position per market,
   * kept in step by each position write. getSessionState reads this one row instead of scanning
   * every wallet's positions on each subscriber re-run.
   */
  umbrellaMarketTotals: defineTable({
    marketId: v.string(),
    stakedUsd6: v.string(),
    cooldownUsd6: v.string(),
    updatedAt: v.number(),
  }).index("by_market", ["marketId"]),

  /**
   * Per-tranche umbrella cooldown source of truth — what the lifecycle reads and mutates;
   * the `positions.cooldown*` fields are only its derived rollup. `startCooldown` inserts
   * one row, so a (wallet, market) can hold several concurrent tranches, each with its own
   * 20-day cooldown clock and 2-day withdrawal window.
   *
   * `status` is the last-mutated persisted value; `getSessionState` recomputes it at read
   * time against `now` so idle time needs no background sweep. `consumed` (fully unstaked
   * or slashed to zero) is kept for activity history but excluded from every live total.
   */
  umbrellaCooldownTranches: defineTable({
    positionId: v.id("positions"),
    wallet: v.string(),
    marketId: v.string(),
    amountUsd6: v.string(),
    startedAt: v.number(),
    endsAt: v.number(),
    windowEndsAt: v.number(),
    status: v.union(v.literal("cooling"), v.literal("ready"), v.literal("expired"), v.literal("consumed")),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_position", ["positionId"])
    .index("by_wallet_market_status", ["wallet", "marketId", "status"])
    .index("by_market_status", ["marketId", "status"]),

  /**
   * Per-wallet token balances behind the swap flow and the dashboard "Wallet" tab; one row
   * per (wallet, assetId, sourceType). `amount` is ASSET-NATIVE, not USD-scaled — pricing
   * happens at render. sourceType: "wallet" = base holding, "position" =
   * claimable/withdrawable credited by an open position (`sourcePositionId` joins
   * `positions`), which position writes keep current so unrealized earnings show live.
   */
  walletBalances: defineTable({
    wallet: v.string(),
    assetId: v.string(),
    amount: v.number(),
    sourceType: v.union(v.literal("wallet"), v.literal("position")),
    sourcePositionId: v.optional(v.id("positions")),
    /**
     * Lets home + action flows filter without a join. "wallet" = plain token holding,
     * "lp" = LP-token collateral for a pool market (assetId is `lp:<marketSlug>`),
     * "returned-lp" = LP from a remove-collateral action, pending withdrawal.
     */
    assetKind: v.optional(v.union(v.literal("wallet"), v.literal("lp"), v.literal("returned-lp"))),
    /** Display symbol, so select lists render without a per-row asset lookup. */
    symbol: v.optional(v.string()),
    /**
     * usd6 (1e6 fixed-point as a decimal string), computed at write time from the row's
     * live price and refreshed by the `tokenPrices` rollup, so reads need no price join.
     */
    valueUsd6: v.optional(v.string()),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_wallet_asset", ["wallet", "assetId"])
    .index("by_wallet_asset_kind", ["wallet", "assetKind"]),

  /**
   * Product-scoped onboarding + wallet balances: the source-of-truth buckets for
   * authenticated sandbox wallets. The frontend `buildConvex*SessionSeed` functions must
   * NEVER mint product funds locally.
   */
  walletLendBalances: defineTable({
    wallet: v.string(),
    marketId: v.string(),
    assetId: v.string(),
    symbol: v.string(),
    amount: v.number(),
    valueUsd: v.number(),
    state: v.union(v.literal("available"), v.literal("deposited")),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_wallet_market_state", ["wallet", "marketId", "state"]),

  walletBorrowBalances: defineTable({
    wallet: v.string(),
    marketId: v.optional(v.string()),
    assetId: v.optional(v.string()),
    poolId: v.optional(v.string()),
    symbol: v.string(),
    amount: v.number(),
    valueUsd: v.number(),
    unitPriceUsd: v.optional(v.number()),
    state: v.union(v.literal("poolAvailable"), v.literal("collateral"), v.literal("debt"), v.literal("claimableFees")),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_wallet_state", ["wallet", "state"])
    .index("by_wallet_market_state", ["wallet", "marketId", "state"]),

  walletMultiplyBalances: defineTable({
    wallet: v.string(),
    marketId: v.optional(v.string()),
    assetId: v.string(),
    symbol: v.string(),
    amount: v.number(),
    valueUsd: v.number(),
    state: v.union(v.literal("available"), v.literal("collateral"), v.literal("debt"), v.literal("position")),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_wallet_asset_state", ["wallet", "assetId", "state"]),

  walletLiquidBalances: defineTable({
    wallet: v.string(),
    assetId: v.string(),
    symbol: v.string(),
    amount: v.number(),
    valueUsd: v.number(),
    state: v.literal("available"),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_wallet_asset", ["wallet", "assetId"]),

  /**
   * USD per LP token for a pool market, feeding the pledge-flow "you deposit N LP ≈ $X"
   * previews. Kept out of `marketDailyStats` because LP prices tick faster than daily;
   * refreshed on the market-snapshots cache interval.
   */
  lpTokenPrices: defineTable({
    slug: v.string(),
    priceUsd: v.number(),
    updatedAt: v.number(),
  }).index("by_slug", ["slug"]),

  /**
   * Per-market fee APY as a WAD (1e18 fixed-point, decimal string), derived from
   * `marketDailyStats.supplyApyPct` at rollup. Split out so the credit engine's
   * `accrueLinearIndex` reads a stable wad instead of re-parsing and rounding a
   * percentage on the hot path.
   */
  feeApyWads: defineTable({
    slug: v.string(),
    feeApyWad: v.string(),
    updatedAt: v.number(),
  }).index("by_slug", ["slug"]),

  /**
   * BorrowSpoke registry, mirroring BORROW_SPOKES in `app/lib/borrow-sim.ts`. Feeds spoke
   * headings, the isSmartSpoke filter, risk-model labels, `getSpokeById` and SPOKE_SLUGS
   * routing.
   */
  spokes: defineTable({
    id: v.string(),
    slug: v.string(),
    dex: v.string(),
    label: v.string(),
    description: v.string(),
    eMode: v.optional(v.string()),
    maxLtvPct: v.number(),
    aprApproxPct: v.number(),
    riskPremiumBps: v.number(),
    liquidityUsd: v.number(),
    liquidationUsdApprox: v.number(),
    bgClass: v.string(),
    textClass: v.string(),
    borrowableTokens: v.array(
      v.object({
        symbol: v.string(),
        iconUrl: v.string(),
        shortLabel: v.string(),
        bgClass: v.string(),
        textClass: v.string(),
      }),
    ),
    isSmartSpoke: v.boolean(),
    updatedAt: v.number(),
  })
    .index("by_key", ["id"])
    .index("by_slug", ["slug"]),

  /** DEX catalog, mirroring BORROW_DEXES. */
  dexes: defineTable({
    id: v.string(),
    label: v.string(),
    tvlUsd: v.number(),
    bgClass: v.string(),
    textClass: v.string(),
    updatedAt: v.number(),
  }).index("by_key", ["id"]),

  /**
   * Global borrowable-asset registry, one row per (spokeId, baseAssetId), mirroring
   * `app/lib/borrow-system/registry.ts`. Read by pool + asset landing rows, "Assets You
   * Can Borrow", and asset-detail cross-market links.
   */
  borrowAssets: defineTable({
    id: v.string(),
    spokeId: v.string(),
    baseAssetId: v.string(),
    name: v.string(),
    symbol: v.string(),
    subtitle: v.string(),
    category: v.string(),
    contextLabel: v.string(),
    displayVisual: v.object({
      symbol: v.string(),
      iconUrl: v.string(),
      shortLabel: v.string(),
      bgClass: v.string(),
      textClass: v.string(),
    }),
    baseBorrowAprPct: v.number(),
    totalCapacityUsd: v.number(),
    utilizationPct: v.number(),
    totalBorrowedUsd: v.number(),
    availableUsd: v.number(),
    reserveFactorPct: v.optional(v.number()),
    marketIds: v.array(v.string()),
    updatedAt: v.number(),
  })
    .index("by_key", ["id"])
    .index("by_spoke", ["spokeId"])
    .index("by_base_asset", ["baseAssetId"]),

  /** Multiply IRM parameters, one row per market slug. Mirrors `borrowInterestRateModels`. */
  multiplyInterestRateModels: defineTable({
    slug: v.string(),
    optimalUtilizationPct: v.number(),
    slopeBelowOptimalPct: v.number(),
    slopeAboveOptimalPct: v.number(),
    baseBorrowRatePct: v.number(),
    source: v.optional(v.union(v.literal("seed"), v.literal("chain"))),
    txHash: v.optional(v.string()),
    updatedAt: v.number(),
  }).index("by_slug", ["slug"]),

  /**
   * Per-multiply-market allocation across contributing pools. Same shape as the asset
   * allocation cards, keyed by `multiplyMarkets.slug`.
   */
  multiplyMarketAllocations: defineTable({
    marketSlug: v.string(),
    rowKey: v.string(),
    poolSlug: v.string(),
    poolName: v.string(),
    venueLabel: v.string(),
    sharePct: v.number(),
    valueUsd: v.number(),
    utilizationPct: v.number(),
    borrowAprPct: v.number(),
    collateralFactorPct: v.number(),
    updatedAt: v.number(),
  }).index("by_market", ["marketSlug"]),

  /** Per-token multiply parameters; mirrors the MULTIPLY_TOKEN_* maps in `multiply-sim.ts`. */
  multiplyTokenParameters: defineTable({
    symbol: v.string(),
    supplyApyPct: v.number(),
    borrowAprPct: v.number(),
    availableUsd: v.number(),
    collateralFactorPct: v.number(),
    liquidationThresholdPct: v.number(),
    iconUrl: v.string(),
    updatedAt: v.number(),
  }).index("by_symbol", ["symbol"]),

  // Contract addresses — seeded synthetic 0x… strings. Split by scope to keep indexes narrow.

  poolContractAddresses: defineTable({
    poolSlug: v.string(),
    salt: v.string(),
    address: v.string(),
    label: v.string(),
    href: v.string(),
    chain: v.string(),
    isSynthetic: v.boolean(),
    updatedAt: v.number(),
  })
    .index("by_pool_salt", ["poolSlug", "salt"])
    .index("by_pool", ["poolSlug"]),

  assetContractAddresses: defineTable({
    assetSlug: v.string(),
    salt: v.string(),
    address: v.string(),
    label: v.string(),
    href: v.string(),
    chain: v.string(),
    isSynthetic: v.boolean(),
    updatedAt: v.number(),
  })
    .index("by_asset_salt", ["assetSlug", "salt"])
    .index("by_asset", ["assetSlug"]),

  multiplyContractAddresses: defineTable({
    marketSlug: v.string(),
    salt: v.string(),
    address: v.string(),
    label: v.string(),
    href: v.string(),
    chain: v.string(),
    isSynthetic: v.boolean(),
    updatedAt: v.number(),
  })
    .index("by_market_salt", ["marketSlug", "salt"])
    .index("by_market", ["marketSlug"]),

  lendContractAddresses: defineTable({
    marketSlug: v.string(),
    salt: v.string(),
    address: v.string(),
    label: v.string(),
    href: v.string(),
    chain: v.string(),
    isSynthetic: v.boolean(),
    updatedAt: v.number(),
  })
    .index("by_market_salt", ["marketSlug", "salt"])
    .index("by_market", ["marketSlug"]),

  // Per-wallet portfolio: the home page IS the connected wallet's portfolio. The test
  // wallet is a seeded "test-wallet-000" row; production wallets use non-colliding hex.

  /** Home page collateral cards + the action-page sidebar HomeCollateralPool. */
  walletCollateralPositions: defineTable({
    wallet: v.string(),
    homePoolId: v.string(),
    marketId: v.string(),
    name: v.string(),
    venueLabel: v.string(),
    category: v.string(),
    collateralUsd: v.number(),
    maxLtvPct: v.number(),
    borrowPowerUsd: v.number(),
    liquidationUsd: v.number(),
    pairAprPct: v.number(),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_wallet_home_pool", ["wallet", "homePoolId"])
    .index("by_wallet_market", ["wallet", "marketId"]),

  /** UI view of open debts, per wallet. */
  walletDebts: defineTable({
    wallet: v.string(),
    homePoolId: v.string(),
    marketId: v.string(),
    debtAssetId: v.string(),
    amountUsd: v.number(),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_wallet_home_pool", ["wallet", "homePoolId"]),

  /**
   * Rewards / fee claim positions on the home page. `breakdown` is inline so one query
   * renders the whole card.
   */
  walletClaimPositions: defineTable({
    wallet: v.string(),
    claimId: v.string(),
    homePoolId: v.string(),
    marketId: v.string(),
    name: v.string(),
    subtitle: v.string(),
    totalUsd: v.number(),
    breakdown: v.array(
      v.object({
        symbol: v.string(),
        amountLabel: v.string(),
        amountToken: v.number(),
        usdValue: v.number(),
        visualSymbol: v.string(),
      }),
    ),
    updatedAt: v.number(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_wallet_claim", ["wallet", "claimId"]),

  /** Owner mapping and lifecycle metadata for Convex Agent Ask AI threads. */
  askAIThreads: defineTable({
    threadId: v.string(),
    ownerSubject: v.string(),
    title: v.string(),
    status: v.union(v.literal("active"), v.literal("archived")),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_thread", ["threadId"])
    .index("by_owner_status_updated", ["ownerSubject", "status", "updatedAt"]),

  /** Rich assistant-ui parts persisted alongside the Agent message text. */
  askAIMessageParts: defineTable({
    threadId: v.string(),
    messageId: v.string(),
    parts: v.any(),
    createdAt: v.number(),
  })
    .index("by_thread", ["threadId"])
    .index("by_message", ["messageId"]),

  askAIBudgetReservations: defineTable({
    ownerSubject: v.string(),
    tokens: v.number(),
    settled: v.boolean(),
    createdAt: v.number(),
  }).index("by_owner_created", ["ownerSubject", "createdAt"]),

  /** Bounded hourly token totals used by Ask AI quota reads instead of scanning every row. */
  askAICostBuckets: defineTable({
    ownerSubject: v.string(),
    bucketStart: v.number(),
    usedTokens: v.number(),
    reservedTokens: v.number(),
    updatedAt: v.number(),
  }).index("by_owner_bucket", ["ownerSubject", "bucketStart"]),

  /** Marks that legacy usage/reservations were folded into the bounded cost buckets. */
  askAIQuotaState: defineTable({
    ownerSubject: v.string(),
    initializedAt: v.number(),
  }).index("by_owner", ["ownerSubject"]),

  askAITurns: defineTable({
    capacityAttempts: v.optional(v.number()),
    nextCapacityRetryAt: v.optional(v.number()),
    budgetReservationId: v.optional(v.id("askAIBudgetReservations")),
    timeoutOutcome: v.optional(
      v.union(
        v.literal("pending"),
        v.literal("completed"),
        v.literal("failed"),
        v.literal("timed_out"),
        v.literal("cancelled"),
      ),
    ),
    threadId: v.string(),
    ownerSubject: v.string(),
    clientRequestId: v.optional(v.string()),
    wallet: v.optional(v.string()),
    promptMessageId: v.string(),
    prompt: v.string(),
    status: v.union(
      v.literal("queued"),
      v.literal("running"),
      v.literal("failed"),
      v.literal("cancelled"),
      v.literal("complete"),
    ),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_owner_request", ["ownerSubject", "clientRequestId"])
    .index("by_prompt_message", ["promptMessageId"])
    .index("by_thread_status_created", ["threadId", "status", "createdAt"])
    .index("by_status_created", ["status", "createdAt"])
    .index("by_owner_status_created", ["ownerSubject", "status", "createdAt"]),

  askAIFeedback: defineTable({
    ownerSubject: v.string(),
    threadId: v.string(),
    messageId: v.string(),
    categories: v.array(v.string()),
    note: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_owner_message", ["ownerSubject", "messageId"])
    .index("by_thread", ["threadId"])
    .index("by_created_at", ["createdAt"]),

  askAIUsage: defineTable({
    ownerSubject: v.string(),
    threadId: v.string(),
    messageId: v.string(),
    model: v.string(),
    provider: v.string(),
    inputTokens: v.number(),
    outputTokens: v.number(),
    totalTokens: v.number(),
    createdAt: v.number(),
  })
    .index("by_owner_created", ["ownerSubject", "createdAt"])
    .index("by_message", ["messageId"]),

  askAITelemetry: defineTable({
    attemptId: v.optional(v.string()),
    timeoutOutcome: v.optional(
      v.union(v.literal("completed"), v.literal("failed"), v.literal("timed_out"), v.literal("cancelled")),
    ),
    ownerSubject: v.string(),
    threadId: v.string(),
    promptMessageId: v.string(),
    status: v.union(v.literal("complete"), v.literal("failed"), v.literal("cancelled")),
    model: v.optional(v.string()),
    provider: v.optional(v.string()),
    durationMs: v.number(),
    inputTokens: v.optional(v.number()),
    outputTokens: v.optional(v.number()),
    totalTokens: v.optional(v.number()),
    cacheReadTokens: v.optional(v.number()),
    cacheWriteTokens: v.optional(v.number()),
    serviceTier: v.optional(v.string()),
    tools: v.array(v.string()),
    routeIntent: v.optional(v.string()),
    toolBudget: v.optional(v.number()),
    error: v.optional(v.string()),
    createdAt: v.number(),
  })
    .index("by_attempt", ["attemptId"])
    .index("by_created", ["createdAt"])
    .index("by_status_created", ["status", "createdAt"])
    .index("by_owner_created", ["ownerSubject", "createdAt"]),

  /**
   * One row per deterministic Ask AI mode-run: the mode, the single snapshot it was
   * computed on, and its typed widgets/actions. `widgets`/`actions` hold TS-typed
   * AskAiWidget[]/AskAiAction[]; the write path type-checks them and
   * `convex/askAiRuns.ts` also guards the widget discriminant at write time.
   */
  askAiRuns: defineTable({
    ownerSubject: v.string(),
    threadId: v.optional(v.string()),
    messageId: v.optional(v.string()),
    mode: v.union(v.literal("risk"), v.literal("returns"), v.literal("stress")),
    queryText: v.string(),
    snapshotId: v.string(),
    asOf: v.number(),
    narrative: v.string(),
    widgets: v.array(v.any()),
    actions: v.array(v.any()),
    provenance: v.optional(v.string()),
    createdAt: v.number(),
  })
    .index("by_owner_created", ["ownerSubject", "createdAt"])
    .index("by_thread", ["threadId"])
    .index("by_snapshot", ["snapshotId"]),

  /** Normalized cache populated only by external market-provider ingestion. */
  askAIMarketSnapshots: defineTable({
    // Only coingecko/defillama/aave are writable by current ingestion, but the legacy
    // literals must stay until prod rows are cleaned up — narrowing first makes Convex
    // reject the existing documents during schema validation.
    source: v.union(
      v.literal("coingecko"),
      v.literal("defillama"),
      v.literal("uniswap"),
      v.literal("curve"),
      v.literal("balancer"),
      v.literal("aave"),
    ),
    kind: v.union(v.literal("token_price"), v.literal("dex_pool"), v.literal("lending_market")),
    key: v.string(),
    payload: v.any(),
    sourceUpdatedAt: v.optional(v.number()),
    fetchedAt: v.number(),
    contentHash: v.optional(v.string()),
  })
    .index("by_source_kind_key", ["source", "kind", "key"])
    .index("by_kind_key", ["kind", "key"])
    .index("by_fetched_at", ["fetchedAt"]),

  askAIMarketProviderRuns: defineTable({
    // Historical run rows use the same legacy source set as market snapshots.
    source: v.union(
      v.literal("coingecko"),
      v.literal("defillama"),
      v.literal("uniswap"),
      v.literal("curve"),
      v.literal("balancer"),
      v.literal("aave"),
    ),
    status: v.union(v.literal("success"), v.literal("failed")),
    records: v.number(),
    error: v.optional(v.string()),
    startedAt: v.number(),
    completedAt: v.number(),
  })
    .index("by_source_completed", ["source", "completedAt"])
    .index("by_status_completed", ["status", "completedAt"]),

  /** Bounded latest ingestion health; one document per active market provider. */
  askAIMarketProviderState: defineTable({
    source: v.union(v.literal("defillama"), v.literal("aave")),
    status: v.union(v.literal("success"), v.literal("failed")),
    records: v.number(),
    inserted: v.number(),
    updated: v.number(),
    unchanged: v.number(),
    error: v.optional(v.string()),
    httpStatus: v.optional(v.number()),
    retryAt: v.optional(v.number()),
    startedAt: v.number(),
    completedAt: v.number(),
    lastCheckedAt: v.number(),
    lastChangedAt: v.optional(v.number()),
    lastSuccessAt: v.optional(v.number()),
    lastFailureAt: v.optional(v.number()),
  }).index("by_source", ["source"]),
})
