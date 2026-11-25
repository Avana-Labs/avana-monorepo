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

export default defineSchema({
  /**
   * Per chain: the addresses the sampler reads and the RPC/explorer settings, from the verified release manifest
   * (`deployments:setFromManifest`): Hubs, Spokes, loss layers, each integration's core stack, the markets (two per
   * pool) and the debt reserves.
   */
  deployments: defineTable({
    chainId: v.number(),
    chainSlug: v.string(),
    hubs: v.array(v.object({ address, label: v.string(), tier: v.number() })),
    lendSpokes: v.array(address),
    /** Each CDP Spoke with its home Hub (absent for a Spoke with no market yet). */
    cdpSpokes: v.array(v.object({ address, hub: v.optional(address) })),
    firstLossReserves: v.array(v.object({ address, asset: address, hub: v.optional(address) })),
    deficitOffsets: v.optional(v.array(v.object({ address, asset: address, hub: address }))),
    accessManager: v.optional(address),
    /** One core stack per AMM integration. */
    integrations: v.optional(
      v.array(v.object({ integrationId: v.number(), kind: v.string(), lpVault: address, riskModule: address, liquidationModule: address, aaveAdapter: address, flashloanRepay: address })),
    ),
    /** The manifest's markets, two per pool. */
    markets: v.optional(
      v.array(
        v.object({
          marketId: dec,
          integrationId: v.number(),
          kind: v.union(v.literal("full-range"), v.literal("custom-range")),
          name: v.string(),
          pool: hex,
          spoke: address,
          hub: address,
          vaultToken: address,
          lpOracle: address,
          reserveId: dec,
          tokens: v.array(address),
        }),
      ),
    ),
    debtReserves: v.optional(v.array(v.object({ spoke: address, reserveId: dec, fixedPrice: v.boolean() }))),
    /** The Avana fee recipient (the manifest's `feeRecipient`): the front-end fee's destination. */
    feeRecipient: v.optional(address),
    explorerUrl: v.string(),
    /** Chainlink native/USD feed (8 decimals) used to value gas. */
    nativeUsdFeed: address,
    release: v.string(),
    /** Each Spoke's oracle, for the About card. */
    spokeOracles: v.optional(v.array(v.object({ spoke: address, oracle: address }))),
    /** The manifest's `external` list: third-party contracts (swap venues, tokens, feeds) by group and name. */
    external: v.optional(v.array(v.object({ group: v.string(), name: v.string(), address, standIn: v.boolean() }))),
  }).index("by_chain", ["chainId"]),

  /** One row per (chain, Hub): label, tier, its Lend and CDP Spokes and lend assets. Its totals are its `hubAssets`. */
  hubs: defineTable({
    chainId: v.number(),
    hub: address,
    slug: v.string(),
    label: v.union(v.null(), v.string()),
    tier: v.number(),
    assetCount: v.number(),
    lendAssetIds: v.array(dec),
    lendSpokes: v.array(address),
    cdpSpokes: v.array(address),
    ...read,
  })
    .index("by_key", ["chainId", "hub"])
    .index("by_slug", ["slug"]),

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
      v.object({ firstLossReserve: address, fundedBalance: dec, drawCapSum: dec, required: dec, coverageBoundHolds: v.boolean(), uncovered: dec, deficitOffset: address, offsetFunded: dec }),
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
    /** Each pool has two markets: "full-range" (exact full-range ticks) and "custom-range" (positions inside the band). */
    kind: v.union(v.literal("full-range"), v.literal("custom-range")),
    /** `RiskModule.getMarket(marketId).active`. */
    active: v.boolean(),
    /** The bytes32 pool key (a v3/Slipstream pool address left-padded, or a v4 PoolId). */
    pool: hex,
    tokens: v.array(address),
    tokenDecimals: v.array(v.number()),
    /** The band, fixed for life. */
    bandLower: v.number(),
    bandUpper: v.number(),
    /** The band again under the names the web app's balance reader still uses; removed with the web app's step. */
    tickLower: v.number(),
    tickUpper: v.number(),
    /** The integration kind as bytes32 (`keccak256("AERODROME_SLIPSTREAM")`, `"UNISWAP_V3"` or `"UNISWAP_V4"`), for the same reader. */
    ammProtocol: hex,
    integrationId: v.number(),
    vaultToken: address,
    vaultDecimals: v.number(),
    unitDecimals: v.number(),
    name: v.string(),
    symbol: v.string(),
    lpOracle: address,
    hub: address,
    spoke: address,
    reserveId: dec,
    hubAssetId: dec,
    acceptedPrice: dec,
    /** False while the LPOracle refuses to price (a stale or invalid feed leg). */
    priceAvailable: v.boolean(),
    suppliedUnits: dec,
    suppliedUsd8: dec,
    /** The RiskModule's LTV, the same for both markets of a pool. */
    ltvBps: v.number(),
    collateralFactorBps: v.number(),
    maxLiquidationBonusBps: v.number(),
    liquidationFeeBps: v.number(),
    collateralRiskBps: v.number(),
    /** The vault-token reserve's flags on its Spoke: a depegged Stable or Correlated market is frozen. */
    paused: v.boolean(),
    frozen: v.boolean(),
    liquidation: v.union(
      v.null(),
      v.object({ targetHealthFactorWad: dec, healthFactorForMaxBonusWad: dec, liquidationBonusFactorBps: v.number() }),
    ),
    /** Each debt reserve of the market's Spoke with the market's borrow rate. */
    borrow: v.array(v.object({ reserveId: dec, borrowRateRay: dec })),
    ...read,
  })
    .index("by_key", ["chainId", "integrationId", "marketId"])
    .index("by_slug", ["slug"])
    .index("by_spoke", ["chainId", "spoke"]),

  /** Debt one market backs in one debt reserve, from the latest closed hourly bucket of the indexer's series. */
  marketReserveDebt: defineTable({
    chainId: v.number(),
    /** With `marketId`, the market: each integration's RiskModule numbers its own markets. */
    integrationId: v.number(),
    marketId: dec,
    spoke: address,
    reserveId: dec,
    debt: dec,
    borrowers: v.number(),
    ...read,
  })
    .index("by_market", ["chainId", "integrationId", "marketId"])
    .index("by_reserve", ["chainId", "spoke", "reserveId"]),

  /** One account's collateral and debt value, from the latest daily sample: borrower lists and at-risk counts. */
  positions: defineTable({
    chainId: v.number(),
    spoke: address,
    proxy: address,
    wallet: v.optional(address),
    integrationId: v.number(),
    marketId: dec,
    collateralUnits: dec,
    collateralUsd8: dec,
    debtUsd8: dec,
    ...read,
  })
    .index("by_key", ["chainId", "spoke", "proxy"])
    .index("by_market", ["chainId", "integrationId", "marketId"])
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
    /** The scope's on-chain key: `hub:assetId`, `spoke:reserveId`, `integrationId:marketId`, a Spoke, token or Hub address. */
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
    links: v.optional(
      v.object({
        website: v.optional(v.string()),
        x: v.optional(v.string()),
        docs: v.optional(v.string()),
        github: v.optional(v.string()),
        audits: v.optional(v.array(v.object({ label: v.string(), href: v.string() }))),
      }),
    ),
    risk: v.optional(
      v.object({
        summary: v.string(),
        reviewedAt: v.optional(v.string()),
        factors: v.array(
          v.object({
            id: v.string(),
            label: v.string(),
            level: v.union(v.literal("low"), v.literal("moderate"), v.literal("elevated"), v.literal("high")),
            text: v.string(),
            bps: v.optional(v.number()),
          }),
        ),
        dependencies: v.optional(
          v.array(v.object({ kind: v.union(v.literal("amm"), v.literal("oracle"), v.literal("hub"), v.literal("spoke")), label: v.string(), address: v.string() })),
        ),
      }),
    ),
    /** A Hub page's risk disclosures for its Borrow and Lend pages. */
    disclosures: v.optional(v.object({ borrow: v.optional(v.string()), lend: v.optional(v.string()) })),
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

  /**
   * Accounts announced on chain (`AaveAdapter.AccountCreated`): wallet ↔ proxy, for wallet views and borrower lists.
   * The market is the announcing AaveAdapter's integration's.
   */
  accounts: defineTable({
    chainId: v.number(),
    spoke: address,
    proxy: address,
    wallet: address,
    integrationId: v.number(),
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
    .index("by_tx", ["txHash"])
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
    /** Points redemption rules (lib/redemption.ts); the defaults apply while absent. */
    redemption: v.optional(v.object({ pointsPerStep: v.number(), bpsPerStep: v.number(), days: v.number(), maxBps: v.number() })),
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

  /** The /onboarding step of each wallet (onboarding.ts); the funds themselves come from the local faucet. */
  onboardingProfiles: defineTable({
    wallet: v.string(),
    createdAt: v.number(),
    seedVersion: v.number(),
    onboardingStep: v.string(),
    onboardedAt: v.optional(v.number()),
    eligibilityTier: v.optional(v.number()),
    tierSeed: v.optional(v.string()),
    allocatedUsd: v.optional(v.number()),
    basketSnapshot: v.optional(v.array(v.object({ tokenId: v.string(), amount: v.number(), priceUsdAtClaim: v.number() }))),
    xHandle: v.optional(v.string()),
    tweetUrl: v.optional(v.string()),
    tweetedAt: v.optional(v.number()),
    claimTxSynthetic: v.optional(v.string()),
  }).index("by_wallet", ["wallet"]),

  /** The onboarding seats taken and the USD granted (one row). */
  onboardingEconomy: defineTable({
    userCount: v.number(),
    totalGrantedUsd: v.number(),
    status: v.union(v.literal("open"), v.literal("closed")),
  }),

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
   * When a wallet first interacted with Avana ("Member since"): the earliest of its first on-chain Avana event (the
   * import), its first submitted app transaction (`intents`) and its profile creation. Written only by the server
   * (lib/membership.ts keeps the minimum), never by a client.
   */
  memberships: defineTable({
    wallet: address,
    firstSeenAt: v.number(),
    source: v.union(v.literal("onchain"), v.literal("intent"), v.literal("profile")),
    updatedAt: v.number(),
  }).index("by_wallet", ["wallet"]),

  /**
   * Reward points ledger: one row per award, unique by (wallet, key) so replaying a log or an intent never awards twice.
   * `quest` rows come from the wallet's first on-chain deposit, borrow, repay or pledge; `fee` rows from verified fee
   * payments. Tenure points are not stored: they are computed from the membership at read time (lib/rewards.ts).
   */
  rewardEvents: defineTable({
    wallet: address,
    kind: v.union(v.literal("quest"), v.literal("fee")),
    key: v.string(),
    points: v.number(),
    at: v.number(),
  }).index("by_wallet_key", ["wallet", "key"]),

  /** Markets a wallet pinned to its watchlist (`wallet/pinnedMarkets.ts`); one row per wallet and market page. */
  pinnedMarkets: defineTable({
    wallet: address,
    scope: v.union(v.literal("lend"), v.literal("pool")),
    slug: v.string(),
    pinnedAt: v.number(),
  }).index("by_wallet_slug", ["wallet", "slug"]),

  /** A wallet's older history read once per chain for the rewards (`wallet/backfill.ts`); `truncated` when it was longer than the pages read. */
  historyBackfills: defineTable({
    wallet: address,
    chainId: v.number(),
    doneAt: v.number(),
    truncated: v.boolean(),
  }).index("by_wallet", ["wallet"]),

  /** A wallet's invite code (`lib/referrals.ts`): one per wallet, unique across wallets. */
  referralCodes: defineTable({
    wallet: address,
    code: v.string(),
  })
    .index("by_wallet", ["wallet"])
    .index("by_code", ["code"]),

  /** A wallet that arrived with someone's code: attributed once; `activatedAt` is its first action (a quest-kind log or intent). */
  referralAttributions: defineTable({
    referred: address,
    owner: address,
    code: v.string(),
    capturedAt: v.number(),
    activatedAt: v.optional(v.number()),
  })
    .index("by_referred", ["referred"])
    .index("by_owner", ["owner"]),

  /** Points a wallet spent on a temporary fee discount (`lib/redemption.ts`): `bps` off every fee from `startsAt` to `endsAt`. */
  rewardRedemptions: defineTable({
    wallet: address,
    points: v.number(),
    bps: v.number(),
    startsAt: v.number(),
    endsAt: v.number(),
  }).index("by_wallet_ends", ["wallet", "endsAt"]),

  /** Running sums of a wallet's `rewardEvents`, so a read never scans the ledger; `questIds` are the completed quests. */
  rewardTotals: defineTable({
    wallet: address,
    questPoints: v.number(),
    feePoints: v.number(),
    /** Lend supply so far in USD (each supply valued at the asset's price when it was recorded); drives the volume quest. */
    supplyUsd: v.optional(v.number()),
    /** Points spent on redemptions so far. */
    redeemedPoints: v.optional(v.number()),
    questIds: v.array(v.string()),
    updatedAt: v.number(),
  }).index("by_wallet", ["wallet"]),

  /**
   * Shared per-key rate-limit buckets for the Next API route guards (SIWE nonce/verify/
   * dev-token). Must live here, not in process memory, so a horizontally-scaled deploy
   * enforces ONE limit across instances. `resetAt` = epoch ms the window ends.
   */
  /** Merkl incentives matched to one page at the chain's last successful fetch (incentives.ts). */
  incentives: defineTable({
    chainId: v.number(),
    scope: v.union(v.literal("lend"), v.literal("asset"), v.literal("pool")),
    slug: v.string(),
    aprPct: v.number(),
    rewardTokens: v.array(v.string()),
    opportunities: v.number(),
    updatedAt: v.number(),
  }).index("by_page", ["chainId", "scope", "slug"]),

  /** The last Merkl fetch per chain: `lastOkAt` null until one succeeds. */
  incentiveRuns: defineTable({
    chainId: v.number(),
    lastRunAt: v.number(),
    lastOkAt: v.union(v.number(), v.null()),
    error: v.optional(v.string()),
  }).index("by_chain", ["chainId"]),

  /** Hourly market risk scores (riskScores.ts); the model version names the formula that produced them. */
  riskScores: defineTable({
    chainId: v.number(),
    integrationId: v.number(),
    marketId: v.string(),
    model: v.string(),
    score: v.number(),
    level: v.union(v.literal("low"), v.literal("moderate"), v.literal("elevated"), v.literal("high")),
    factors: v.array(v.object({ id: v.string(), label: v.string(), points: v.number(), value: v.string() })),
    computedAt: v.number(),
  }).index("by_market", ["chainId", "integrationId", "marketId"]),

  /**
   * One day of a market's liquidations or a Hub asset's revenue (rollups.ts), kept past the 30-day log window.
   * `day` is the UTC day `YYYY-MM-DD`; `values` are USD amounts and counts.
   */
  dailyRollups: defineTable({
    chainId: v.number(),
    scopeKind: v.union(v.literal("market"), v.literal("hubAsset")),
    scopeKey: v.string(),
    day: v.string(),
    values: v.record(v.string(), v.number()),
    updatedAt: v.number(),
  }).index("by_scope", ["scopeKind", "scopeKey", "day"]),

  /**
   * Transaction progress of a submitted wallet transaction (lib/intents.ts): the hash, the wallet that signed it and a
   * label, never a target, amount or calldata (REQ-ARCH-140).
   */
  intents: defineTable({
    wallet: address,
    chainId: v.number(),
    txHash: hex,
    kind: v.string(),
    page: v.optional(v.object({ scope: v.union(v.literal("lend"), v.literal("asset"), v.literal("pool")), slug: v.string() })),
    status: v.union(v.literal("pending"), v.literal("included"), v.literal("failed"), v.literal("indexed"), v.literal("confirmed"), v.literal("dropped")),
    submittedAt: v.number(),
    blockNumber: v.optional(dec),
    blockHash: v.optional(hex),
    finalizedAt: v.optional(v.number()),
    /** False once the state is final; the tracker reads open intents, least recently checked first. */
    open: v.boolean(),
    checkedAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_tx", ["chainId", "txHash"])
    .index("by_wallet", ["wallet", "submittedAt"])
    .index("by_open", ["chainId", "open", "checkedAt"]),

  /**
   * Per chain, the intent tracker run that is scheduled while the chain has open intents (intents.ts): `run` is the
   * time it was scheduled and the token that run carries, so only the latest run schedules the next. No row: no
   * tracker is scheduled.
   */
  intentTrackers: defineTable({
    chainId: v.number(),
    run: v.number(),
  }).index("by_chain", ["chainId"]),

  /**
   * SIWE sign-in sessions the web app's server opens and revokes (siweSessions.ts). `sessionId` is the SHA-256 of the
   * session's JWT ID, never the token; a revoked or expired session no longer authorizes per-wallet features.
   */
  siweSessions: defineTable({
    sessionId: v.string(),
    wallet: address,
    issuedAt: v.number(),
    expiresAt: v.number(),
    revokedAt: v.optional(v.number()),
  })
    .index("by_session", ["sessionId"])
    .index("by_wallet", ["wallet", "issuedAt"])
    .index("by_expiry", ["expiresAt"]),

  rateLimitBuckets: defineTable({
    key: v.string(),
    count: v.number(),
    resetAt: v.number(),
  }).index("by_key", ["key"]),

  /**
   * Block timestamps read from Convex's RPC for older activity (`wallet/history:older`), by chain and block number.
   * A row is used only while its hash matches the record's block hash.
   */
  blockTimestamps: defineTable({
    chainId: v.number(),
    blockNumber: dec,
    blockHash: v.string(),
    timestampMs: v.number(),
  }).index("by_block", ["chainId", "blockNumber"]),

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
