// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Markets, debt reserves, oracle states and breakers as last reported by events.
// Price states move with time (Cached, Expired) without an event until the next poke; the Lens is the live value.

import { onchainTable, primaryKey } from "ponder";

export const market = onchainTable(
  "market",
  (t) => ({
    chainId: t.integer().notNull(),
    marketId: t.bigint().notNull(),
    integrationId: t.integer().notNull(),
    spoke: t.hex().notNull(),
    pool: t.hex().notNull(),
    poolId: t.hex().notNull(),
    tokens: t.json().notNull(),
    vaultToken: t.hex().notNull(),
    lpOracle: t.hex().notNull(),
    /** Set on MarketActivated. */
    reserveId: t.bigint(),
    hub: t.hex(),
    hubAssetId: t.bigint(),
    /** Registered, Active, Cancelled, Offboarding or Closed. */
    status: t.text().notNull(),
    settlementReserveId: t.bigint(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.marketId] }) }),
);

/** Key `chainId + Spoke + debtReserveId` (TEST-061). */
export const debtReserve = onchainTable(
  "debt_reserve",
  (t) => ({
    chainId: t.integer().notNull(),
    spoke: t.hex().notNull(),
    debtReserveId: t.bigint().notNull(),
    asset: t.hex().notNull(),
    fundingHub: t.hex().notNull(),
    hubAssetId: t.bigint().notNull(),
    priceSource: t.hex().notNull(),
    coverageSpoke: t.hex().notNull(),
    approved: t.boolean().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.spoke, table.debtReserveId] }) }),
);

/** Last state an LPOracle or DebtOracle emitted. */
export const oracleState = onchainTable(
  "oracle_state",
  (t) => ({
    chainId: t.integer().notNull(),
    oracle: t.hex().notNull(),
    /** "lp" or "debt". */
    kind: t.text().notNull(),
    /** Live, Drifting, Cached or Expired. */
    state: t.text().notNull(),
    reasons: t.bigint().notNull(),
    acceptedPrice: t.bigint(),
    acceptedAt: t.bigint(),
    disagreeSince: t.bigint(),
    graceEndsAt: t.bigint(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.oracle] }) }),
);

/** Breakers keyed by scope (Market or DebtReserve) and key (marketId, or the Spoke and debt reserve hash). */
export const breaker = onchainTable(
  "breaker",
  (t) => ({
    chainId: t.integer().notNull(),
    scope: t.integer().notNull(),
    key: t.hex().notNull(),
    latchedReasons: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.scope, table.key] }) }),
);
