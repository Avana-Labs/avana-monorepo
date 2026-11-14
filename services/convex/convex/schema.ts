// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Convex tables. A chain has several Hubs; every row names its Hub (or, for a market, its CDP Spoke and Hub). Chain
// numbers are stored once, at the narrowest scope that owns them, keyed as the indexer keys them: a Hub asset's
// totals only in `hubAssets`, a Spoke's draw on it only in `hubAssetSpokes`, a CDP reserve's
// flags only in `spokeReserves`, a market's figures only in `markets`. Every page that shows one of them reads that
// row, so the Lend page and the Borrow pages cannot disagree. Integers are decimal strings (base units, RAY rates,
// 8-decimal USD), exactly as read on chain; the queries convert them for display.

import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

/** Lower-case hex address. */
const address = v.string();
const hex = v.string();
const dec = v.string();

/** The block a row was read at; every row of one refresh carries the same one. */
const read = { blockNumber: dec, updatedAt: v.number() };
/** One speed window of the RiskModule as `Lens.getBorrowSpeed` / `getPledgeSpeed` report it (`SpeedWindow`). */
const speedWindow = v.object({ limit: dec, used: dec, available: dec, moreAt: v.number(), moreAmount: dec, unavailable: v.boolean() });

export default defineSchema({
  /**
   * Per chain: the addresses the sampler starts from and the RPC/explorer settings, from the verified release
   * manifest. Hubs the MarketRegistry records and CDP Spokes it approves later are found on chain at each refresh.
   */
  deployments: defineTable({
    chainId: v.number(),
    chainSlug: v.string(),
    lens: address,
    hubs: v.array(v.object({ address, label: v.string(), tier: v.number() })),
    lendSpokes: v.array(address),
    cdpSpokes: v.array(address),
    coverageSpokes: v.array(v.object({ address, asset: address, hub: v.optional(address) })),
    marketRegistry: address,
    timelock: address,
    explorerUrl: v.string(),
    /** Chainlink native/USD feed (8 decimals) used to value gas. */
    nativeUsdFeed: address,
    release: v.string(),
  }).index("by_chain", ["chainId"]),

  /** One row per (chain, Hub): label, tier, its Lend and CDP Spokes and lend assets. Its totals are its `hubAssets`. */
  hubs: defineTable({
    chainId: v.number(),
    hub: address,
    slug: v.string(),
    label: v.union(v.null(), v.string()),
    tier: v.number(),
    recorded: v.boolean(),
    applicationState: v.union(v.null(), v.number()),
    assetCount: v.number(),
    lendAssetIds: v.array(dec),
    lendSpokes: v.array(address),
    cdpSpokes: v.array(address),
    ...read,
  })
    .index("by_key", ["chainId", "hub"])
    .index("by_slug", ["slug"]),

  /** A Hub-to-Hub credit line: the registry's cap; the Spoke's draw on it is its `hubAssetSpokes` row. */
  creditLines: defineTable({
    chainId: v.number(),
    fundingHub: address,
    assetId: dec,
    asset: address,
    spoke: address,
    homeHub: address,
    cap: dec,
    total: dec,
    enabled: v.boolean(),
    ...read,
  })
    .index("by_key", ["chainId", "fundingHub", "assetId", "spoke"])
    .index("by_funding", ["chainId", "fundingHub"])
    .index("by_home", ["chainId", "homeHub"]),

  hubAssets: defineTable({
    chainId: v.number(),
    hub: address,
    assetId: dec,
    slug: v.string(),
    underlying: address,
    decimals: v.number(),
    priceUsd8: dec,
    added: dec,
    addedShares: dec,
    drawn: dec,
    premium: dec,
    owed: dec,
    liquidity: dec,
    deficit: dec,
    accruedFees: dec,
    drawnIndexRay: dec,
    drawnRateRay: dec,
    supplyRateRay: dec,
    utilizationBps: v.number(),
    liquidityFeeBps: v.number(),
    feeReceiver: address,
    rateCurve: v.union(
      v.null(),
      v.object({ optimalUsageBps: v.number(), baseDrawnRateBps: v.number(), rateGrowthBeforeOptimalBps: v.number(), rateGrowthAfterOptimalBps: v.number() }),
    ),
    lend: v.object({ spoke: address, reserveId: dec, paused: v.boolean(), frozen: v.boolean() }),
    lendReserves: v.array(v.object({ spoke: address, reserveId: dec, paused: v.boolean(), frozen: v.boolean() })),
    exposure: v.union(
      v.null(),
      v.object({ coverageSpoke: address, fundedBalance: dec, line: dec, coverageBoundHolds: v.boolean(), uncovered: dec, priceAdj: dec, deficitOffset: address, offsetFunded: dec }),
    ),
    timestamp: v.number(),
    ...read,
  })
    .index("by_key", ["chainId", "hub", "assetId"])
    .index("by_hub", ["chainId", "hub"])
    .index("by_slug", ["slug"])
    .index("by_chain_underlying", ["chainId", "underlying"]),

  hubAssetSpokes: defineTable({
    chainId: v.number(),
    hub: address,
    assetId: dec,
    spoke: address,
    kind: v.union(v.literal("lend"), v.literal("cdp"), v.literal("coverage"), v.literal("feeReceiver"), v.literal("other"), v.literal("deficitOffset")),
    homeHub: address,
    added: dec,
    addedShares: dec,
    owed: dec,
    drawnShares: dec,
    premiumShares: dec,
    deficit: dec,
    addCap: dec,
    drawCap: dec,
    active: v.boolean(),
    halted: v.boolean(),
    ...read,
  })
    .index("by_asset", ["chainId", "hub", "assetId"])
    .index("by_key", ["chainId", "hub", "assetId", "spoke"]),

  spokeReserves: defineTable({
    chainId: v.number(),
    spoke: address,
    reserveId: dec,
    slug: v.string(),
    hub: address,
    assetId: dec,
    asset: address,
    decimals: v.number(),
    debtPrice: dec,
    fixedPrice: v.boolean(),
    paused: v.boolean(),
    frozen: v.boolean(),
    borrowable: v.boolean(),
    breakerReasons: v.number(),
    pauseState: v.number(),
    ...read,
  })
    .index("by_key", ["chainId", "spoke", "reserveId"])
    .index("by_slug", ["slug"])
    .index("by_spoke", ["chainId", "spoke"])
    .index("by_asset", ["chainId", "hub", "assetId"]),

  markets: defineTable({
    chainId: v.number(),
    marketId: dec,
    slug: v.string(),
    status: v.number(),
    pool: address,
    poolId: hex,
    tokens: v.array(address),
    tokenDecimals: v.array(v.number()),
    feeTier: v.number(),
    tickLower: v.number(),
    tickUpper: v.number(),
    integrationId: v.number(),
    ammProtocol: hex,
    vaultToken: address,
    vaultDecimals: v.number(),
    name: v.string(),
    symbol: v.string(),
    lpOracle: address,
    hub: address,
    spoke: address,
    reserveId: dec,
    hubAssetId: dec,
    acceptedPrice: dec,
    priceState: v.number(),
    suppliedUnits: dec,
    suppliedUsd8: dec,
    collateralFactorBps: v.number(),
    maxLiquidationBonusBps: v.number(),
    collateralRiskBps: v.number(),
    liquidation: v.union(
      v.null(),
      v.object({ targetHealthFactorWad: dec, healthFactorForMaxBonusWad: dec, liquidationBonusFactorBps: v.number() }),
    ),
    marketHeadroomUsd8: dec,
    sliceHeadroomUsd8: dec,
    addHeadroom: dec,
    pauseState: v.number(),
    breakerReasons: v.number(),
    /** Each debt reserve of the market's Spoke: the market's borrow rate and what it can borrow now (BOR-024). */
    borrow: v.array(
      v.object({
        reserveId: dec,
        borrowRateRay: dec,
        speed: v.union(v.null(), v.object({ availableNow: dec, moreAt: v.number(), market: speedWindow, debt: speedWindow })),
      }),
    ),
    pledgeSpeed: v.union(v.null(), speedWindow),
    ...read,
  })
    .index("by_key", ["chainId", "marketId"])
    .index("by_slug", ["slug"])
    .index("by_spoke", ["chainId", "spoke"]),

  /** Debt one market backs in one debt reserve, from the latest closed hourly bucket of the indexer's series. */
  marketReserveDebt: defineTable({
    chainId: v.number(),
    marketId: dec,
    spoke: address,
    reserveId: dec,
    debt: dec,
    borrowers: v.number(),
    ...read,
  })
    .index("by_market", ["chainId", "marketId"])
    .index("by_reserve", ["chainId", "spoke", "reserveId"]),

  /** One account's collateral and debt value, from the latest daily sample: borrower lists and at-risk counts. */
  positions: defineTable({
    chainId: v.number(),
    spoke: address,
    proxy: address,
    wallet: v.optional(address),
    marketId: dec,
    collateralUnits: dec,
    collateralUsd8: dec,
    debtUsd8: dec,
    ...read,
  })
    .index("by_key", ["chainId", "spoke", "proxy"])
    .index("by_market", ["chainId", "marketId"])
    .index("by_wallet", ["wallet"]),

  /** Every chart point, by scope. `source` separates a pool's pre-listing history from its live buckets. */
  series: defineTable({
    chainId: v.number(),
    scopeKind: v.string(),
    scopeKey: v.string(),
    resolution: v.union(v.literal("hour"), v.literal("day")),
    bucketStart: v.number(),
    source: v.union(v.literal("live"), v.literal("history")),
    blockNumber: dec,
    values: v.record(v.string(), dec),
  })
    .index("by_scope", ["scopeKind", "scopeKey", "resolution", "bucketStart"])
    .index("by_bucket", ["scopeKind", "scopeKey", "resolution", "bucketStart", "source"])
    .index("by_resolution_time", ["resolution", "bucketStart"]),

  /**
   * Editorial content of one page, loaded from the listing metadata file whose hash the governance operation commits
   * to. `scope` is the page kind: lend (Hub asset), asset (CDP debt reserve), pool (market), spoke, token or hub.
   */
  marketContent: defineTable({
    scope: v.union(v.literal("lend"), v.literal("asset"), v.literal("pool"), v.literal("spoke"), v.literal("token"), v.literal("hub")),
    chainId: v.number(),
    /** The scope's on-chain key: `hub:assetId`, `spoke:reserveId`, `marketId`, a Spoke, token or Hub address. */
    key: v.string(),
    slug: v.string(),
    name: v.string(),
    symbol: v.optional(v.string()),
    category: v.optional(v.union(v.literal("stable"), v.literal("crypto"), v.literal("stock"))),
    venueLabel: v.optional(v.string()),
    iconUrl: v.optional(v.string()),
    description: v.string(),
    longText: v.optional(v.string()),
    stats: v.array(v.object({ label: v.string(), value: v.string(), href: v.optional(v.string()) })),
    history: v.array(v.object({ date: v.string(), title: v.string(), description: v.optional(v.string()) })),
    faqs: v.array(v.object({ question: v.string(), answer: v.string() })),
    visuals: v.optional(
      v.array(v.object({ symbol: v.string(), shortLabel: v.string(), bgClassName: v.string(), textClassName: v.string(), iconUrl: v.optional(v.string()) })),
    ),
    resources: v.optional(v.array(v.object({ label: v.string(), href: v.string() }))),
    contentHash: v.string(),
    operationId: v.string(),
    loadedAt: v.number(),
  })
    .index("by_key", ["scope", "chainId", "key"])
    .index("by_slug", ["scope", "slug"]),

  /** Timelock operations that may carry listing metadata: the salt is the keccak256 of the metadata file. */
  listingOperations: defineTable({
    chainId: v.number(),
    operationId: v.string(),
    salt: v.string(),
    status: v.union(v.literal("scheduled"), v.literal("executed"), v.literal("loaded"), v.literal("noMetadata"), v.literal("rejected")),
    executedBlock: v.optional(dec),
    error: v.optional(v.string()),
    updatedAt: v.number(),
  }).index("by_op", ["chainId", "operationId"]),

  /** Configuration changes shown in each page's changelog, derived from ingested events. */
  parameterChanges: defineTable({
    chainId: v.number(),
    scope: v.union(v.literal("lend"), v.literal("asset"), v.literal("pool"), v.literal("chain")),
    key: v.string(),
    parameter: v.string(),
    previous: v.string(),
    current: v.string(),
    at: v.number(),
    blockNumber: dec,
    txHash: v.string(),
    source: v.string(),
  })
    .index("by_scope", ["scope", "chainId", "key", "at"])
    .index("by_parameter", ["chainId", "scope", "key", "parameter", "at"]),

  /** Accounts announced on chain (UserProxyCreated): wallet ↔ proxy, for wallet views and borrower lists. */
  accounts: defineTable({
    chainId: v.number(),
    spoke: address,
    proxy: address,
    wallet: address,
    marketId: dec,
    blockNumber: dec,
  })
    .index("by_key", ["chainId", "spoke", "proxy"])
    .index("by_wallet", ["wallet"]),

  /** Export import state, one row per chain (README, "Scheduled pull"). */
  ingestCheckpoints: defineTable({
    chainId: v.number(),
    throughBlock: dec,
    throughBlockHash: v.string(),
    schemaVersion: v.number(),
    lastPageHash: v.string(),
    seriesThroughTime: v.number(),
    updatedAt: v.number(),
  }).index("by_chain", ["chainId"]),

  ingestCheckpointHistory: defineTable({
    chainId: v.number(),
    throughBlock: dec,
    throughBlockHash: v.string(),
  }).index("by_chain_block", ["chainId", "throughBlock"]),

  /**
   * Recent decoded logs (30 days) with the scope keys the activity feeds filter by. `key` is `chainId:txHash:logIndex`,
   * the duplicate check of the import.
   */
  ingestedLogs: defineTable({
    key: v.string(),
    chainId: v.number(),
    kind: v.string(),
    blockNumber: dec,
    blockHash: v.string(),
    txHash: v.string(),
    logIndex: v.number(),
    address,
    at: v.number(),
    args: v.any(),
    hubAssetKey: v.optional(v.string()),
    spokeReserveKey: v.optional(v.string()),
    marketKey: v.optional(v.string()),
    wallet: v.optional(address),
  })
    .index("by_key", ["key"])
    .index("by_hub_asset", ["hubAssetKey", "at"])
    .index("by_spoke_reserve", ["spokeReserveKey", "at"])
    .index("by_market", ["marketKey", "at"])
    .index("by_wallet", ["wallet", "at"])
    .index("by_at", ["at"]),

  /** Progress of each pool's pre-listing history import; ranges apply in order, each once. */
  poolBackfills: defineTable({
    chainId: v.number(),
    pool: address,
    fromBlock: dec,
    throughBlock: dec,
    listedBlock: dec,
    updatedAt: v.number(),
  }).index("by_pool", ["chainId", "pool"]),

  /** Frontend fee rules (one row, `key` "default"); every rate within 0..MAX_FEE_BPS (25). No recipient: the app reads `feeRecipient` on chain. */
  feeConfig: defineTable({
    key: v.string(),
    enabled: v.boolean(),
    defaultBps: v.number(),
    actionBps: v.record(v.string(), v.number()),
    exemptActions: v.array(v.string()),
    maxFeeUsd: v.union(v.null(), v.number()),
    updatedAt: v.number(),
  }).index("by_key", ["key"]),

  /** Gas price and native token price per chain, refreshed by a cron for the total shown before signing. */
  chainGas: defineTable({
    chainId: v.number(),
    baseFeeWei: dec,
    priorityFeeWei: dec,
    nativeUsd8: dec,
    blockNumber: dec,
    updatedAt: v.number(),
  }).index("by_chain", ["chainId"]),

  // ---- App features (moved from the web app's former backend): token prices for tokens outside the protocol,
  // FX, support requests, wallet preferences, the SIWE route rate limiter and Ask AI. ----

  /**
   * Real token spot prices — the ONE place the app reads live market data
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

  /** Permanent wallet identity and display preferences, independent of sign-in. */
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
});
