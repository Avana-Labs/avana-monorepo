// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Every indexed log, with its provenance, and the per-chain indexing progress the export reads.

import { index, onchainTable, primaryKey } from "ponder";

/** One row per log the indexer handles; the export serves this table in (blockNumber, logIndex) order. */
export const eventLog = onchainTable(
  "event_log",
  (t) => ({
    chainId: t.integer().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
    blockHash: t.hex().notNull(),
    blockTimestamp: t.bigint().notNull(),
    address: t.hex().notNull(),
    /** `<Contract>.<Event>`, the names in EVENTS.md. */
    kind: t.text().notNull(),
    /** Decoded arguments; bigints as decimal strings. */
    args: t.json().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.txHash, table.logIndex] }),
    orderIdx: index().on(table.chainId, table.blockNumber, table.logIndex),
    kindIdx: index().on(table.chainId, table.kind, table.blockNumber),
  }),
);

/**
 * Every address a log's arguments name, one row per (log, address), written with the log row. The wallet history
 * (`/export/v1/history`) finds a wallet's and its proxies' logs here instead of searching `event_log.args`.
 */
export const logParty = onchainTable(
  "log_party",
  (t) => ({
    chainId: t.integer().notNull(),
    party: t.hex().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.party, table.txHash, table.logIndex] }),
    partyIdx: index().on(table.chainId, table.party, table.blockNumber),
  }),
);

/** Last block the indexer finished per chain, written by the `Progress:block` handler at the realtime head. */
export const chainProgress = onchainTable("chain_progress", (t) => ({
  chainId: t.integer().primaryKey(),
  blockNumber: t.bigint().notNull(),
  blockHash: t.hex().notNull(),
  blockTimestamp: t.bigint().notNull(),
}));
