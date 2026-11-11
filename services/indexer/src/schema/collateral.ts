// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Collateral records in Collateralization, positions in custody of each LPVault, and pending seized units.

import { index, onchainTable, primaryKey } from "ponder";

/** Key `chainId + Collateralization + recordId` (TEST-061). */
export const collateralRecord = onchainTable(
  "collateral_record",
  (t) => ({
    chainId: t.integer().notNull(),
    collateralization: t.hex().notNull(),
    recordId: t.bigint().notNull(),
    integrationId: t.integer().notNull(),
    positionKey: t.hex().notNull(),
    depositor: t.hex().notNull(),
    proxy: t.hex().notNull(),
    vaultToken: t.hex().notNull(),
    /** Credited units after the last event; Collateralization.getRecord is the live value. */
    credited: t.bigint().notNull(),
    rescueUnits: t.bigint().notNull(),
    open: t.boolean().notNull(),
    lastBlock: t.bigint().notNull(),
    lastBlockHash: t.hex().notNull(),
    lastLogIndex: t.integer().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.collateralization, table.recordId] }),
    proxyIdx: index().on(table.chainId, table.proxy, table.vaultToken),
    depositorIdx: index().on(table.chainId, table.depositor),
  }),
);

/** A position (NFT) held by an LPVault: received on pledge, returned on release. */
export const lpPosition = onchainTable(
  "lp_position",
  (t) => ({
    chainId: t.integer().notNull(),
    lpVault: t.hex().notNull(),
    positionKey: t.hex().notNull(),
    marketId: t.bigint().notNull(),
    depositor: t.hex().notNull(),
    held: t.boolean().notNull(),
    /** True for an NFT sent without a pledge (stray); it is returned, never credited. */
    stray: t.boolean().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.lpVault, table.positionKey] }),
    depositorIdx: index().on(table.chainId, table.depositor),
  }),
);

/** Seized units waiting for `settlePending`: + on SeizureReconciled, − on PendingSettled. `getPending` is the live value. */
export const pendingSettlement = onchainTable(
  "pending_settlement",
  (t) => ({
    chainId: t.integer().notNull(),
    vaultToken: t.hex().notNull(),
    units: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.vaultToken] }) }),
);
