// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Chart series by scope and the AMM pools the indexer follows. One table holds every bucket of every scope
// (`@avana/services-common/series`); the series export serves closed buckets to Convex.

import { index, onchainTable, primaryKey } from "ponder";

/**
 * One bucket of one scope. Sampled scopes (Hub asset, Spoke slice, market, market debt, position) are written once,
 * by the first sample block in the bucket; pool buckets accumulate every swap, mint and burn by their merge rules.
 */
export const seriesPoint = onchainTable(
  "series_point",
  (t) => ({
    chainId: t.integer().notNull(),
    scopeKind: t.text().notNull(),
    scopeKey: t.text().notNull(),
    /** "hour" or "day". */
    resolution: t.text().notNull(),
    bucketStart: t.integer().notNull(),
    /** First second after the bucket; the export serves a bucket once this is at or before the finalized block's time. */
    bucketEnd: t.integer().notNull(),
    /** Block of the sample, or of the last log merged into a summed bucket. */
    blockNumber: t.bigint().notNull(),
    /** Metric → decimal string. */
    values: t.json().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.scopeKind, table.scopeKey, table.resolution, table.bucketStart] }),
    endIdx: index().on(table.chainId, table.bucketEnd),
  }),
);

/** Each pool a listed market uses, from `MarketRegistered`; the swap handler reads its fee here. */
export const ammPool = onchainTable(
  "amm_pool",
  (t) => ({
    chainId: t.integer().notNull(),
    pool: t.hex().notNull(),
    integrationId: t.integer().notNull(),
    /** Fee in pips; for a dynamic-fee pool the value read at the last sample block. */
    feePips: t.integer().notNull(),
    /** Block of the first `MarketRegistered` naming the pool: logs before it come from the history endpoint. */
    listedBlock: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.pool] }) }),
);
