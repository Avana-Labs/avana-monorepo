// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Liquidations, helper calls, payout escrow credits and the committed-operator registry.

import { index, onchainTable, primaryKey } from "ponder";

/** One row per `LPVaultSwap.LiquidationSettled`, with its SettlementReport. Valid whoever the caller is (Q-404). */
export const liquidation = onchainTable(
  "liquidation",
  (t) => ({
    chainId: t.integer().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
    blockNumber: t.bigint().notNull(),
    blockHash: t.hex().notNull(),
    caller: t.hex().notNull(),
    proxy: t.hex().notNull(),
    marketId: t.bigint().notNull(),
    debtReserveId: t.bigint().notNull(),
    debtAsset: t.hex().notNull(),
    debtRepaid: t.bigint().notNull(),
    unitsSeized: t.bigint().notNull(),
    recovered: t.bigint().notNull(),
    minOut: t.bigint().notNull(),
    callerFunds: t.bigint().notNull(),
    avanaFee: t.bigint().notNull(),
    borrowerSurplus: t.bigint().notNull(),
    keeperOut: t.bigint().notNull(),
    minPayout: t.bigint().notNull(),
    shortfall: t.bigint().notNull(),
    /** 0 PrimaryThenBackup, 1 BackupOnly. */
    routeMode: t.integer().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.txHash, table.logIndex] }),
    proxyIdx: index().on(table.chainId, table.proxy),
    marketIdx: index().on(table.chainId, table.marketId, table.blockNumber),
  }),
);

/** Unclaimed PayoutEscrow credit per token and account, so the app can show it. */
export const escrowCredit = onchainTable(
  "escrow_credit",
  (t) => ({
    chainId: t.integer().notNull(),
    token: t.hex().notNull(),
    account: t.hex().notNull(),
    claimable: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.token, table.account] }),
    accountIdx: index().on(table.chainId, table.account),
  }),
);

/** LPVaultSwap's committed-operator registry (KeeperAdded, KeeperRemoved). It gates no call (Q-404). */
export const committedOperator = onchainTable(
  "committed_operator",
  (t) => ({
    chainId: t.integer().notNull(),
    operator: t.hex().notNull(),
    active: t.boolean().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.operator] }) }),
);
