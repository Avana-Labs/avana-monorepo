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
    firstLossReserves: v.array(v.object({ address, asset: address, hub: v.optional(address) })),
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
      v.object({ firstLossReserve: address, fundedBalance: dec, line: dec, coverageBoundHolds: v.boolean(), uncovered: dec, priceAdj: dec, deficitOffset: address, offsetFunded: dec }),
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
});
