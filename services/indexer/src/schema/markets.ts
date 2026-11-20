// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Markets and debt reserves of every RiskModule.

import { onchainTable, primaryKey } from "ponder";

/**
 * One row per market: each pool listed gets two, Full range and Custom range, each with its band, fixed for life
 * (`MarketListed`, emitted first), then the Spoke, listing tick and LTV both share (`PoolListed`). `MarketActivated`
 * sets the vault token, LPOracle and reserve.
 */
export const market = onchainTable(
  "market",
  (t) => ({
    chainId: t.integer().notNull(),
    marketId: t.bigint().notNull(),
    riskModule: t.hex().notNull(),
    integrationId: t.integer().notNull(),
    /** The bytes32 pool key (a v3/Slipstream pool address left-padded, or a v4 PoolId). */
    pool: t.hex().notNull(),
    /** Set by `PoolListed`. */
    spoke: t.hex(),
    /** "full-range" or "custom-range". */
    kind: t.text().notNull(),
    bandLower: t.integer().notNull(),
    bandUpper: t.integer().notNull(),
    /** Set by `PoolListed`; the same for both markets of the pool. */
    listingTick: t.integer(),
    ltvBps: t.integer(),
    unitDecimals: t.integer().notNull(),
    vaultToken: t.hex(),
    lpOracle: t.hex(),
    reserveId: t.bigint(),
    active: t.boolean().notNull(),
    listedBlock: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.marketId] }) }),
);

/** Key `chainId + RiskModule + Spoke + debtReserveId`: a debt reserve a RiskModule lets its markets borrow. */
export const debtReserve = onchainTable(
  "debt_reserve",
  (t) => ({
    chainId: t.integer().notNull(),
    riskModule: t.hex().notNull(),
    spoke: t.hex().notNull(),
    debtReserveId: t.bigint().notNull(),
    hub: t.hex().notNull(),
    asset: t.hex().notNull(),
    firstLossReserve: t.hex().notNull(),
    listed: t.boolean().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.riskModule, table.spoke, table.debtReserveId] }) }),
);
