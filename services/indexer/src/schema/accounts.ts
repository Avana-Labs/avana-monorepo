// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Accounts (one PositionProxy per wallet, CDP Spoke and market) and their historical debt shares.
// Debt, interest and health factor change without events: these rows choose what to read, never what to show
// (services/README.md, Indexer > Rules).

import { index, onchainTable, primaryKey } from "ponder";

/**
 * One account proxy per (wallet, market), from `AaveAdapter.AccountCreated`; key `chainId + Spoke + proxy`, the Spoke
 * being the market's. Spoke events are attributed only to an account the AaveAdapter announced.
 */
export const account = onchainTable(
  "account",
  (t) => ({
    chainId: t.integer().notNull(),
    spoke: t.hex().notNull(),
    proxy: t.hex().notNull(),
    wallet: t.hex().notNull(),
    /** The integration of the AaveAdapter that deployed it; with `marketId`, the account's market. */
    integrationId: t.integer().notNull(),
    marketId: t.bigint().notNull(),
    /** The AaveAdapter that deployed it (one per integration). */
    adapter: t.hex().notNull(),
    /** Last `SetUsingAsCollateral` value on the Spoke for the market's vault-token reserve. */
    usingAsCollateral: t.boolean().notNull(),
    createdBlock: t.bigint().notNull(),
    createdBlockHash: t.hex().notNull(),
    createdTxHash: t.hex().notNull(),
    createdLogIndex: t.integer().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.spoke, table.proxy] }),
    walletIdx: index().on(table.chainId, table.wallet),
    proxyIdx: index().on(table.chainId, table.proxy),
  }),
);

/** Historical drawn shares per account and debt reserve, from the Spoke's Borrow, Repay, LiquidationCall and ReportDeficit. */
export const accountDebt = onchainTable(
  "account_debt",
  (t) => ({
    chainId: t.integer().notNull(),
    spoke: t.hex().notNull(),
    proxy: t.hex().notNull(),
    debtReserveId: t.bigint().notNull(),
    drawnShares: t.bigint().notNull(),
    /** True once the Spoke reported the account's remaining debt in this reserve as deficit. */
    deficitReported: t.boolean().notNull(),
    lastBlock: t.bigint().notNull(),
    lastBlockHash: t.hex().notNull(),
    lastLogIndex: t.integer().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.spoke, table.proxy, table.debtReserveId] }),
    reserveIdx: index().on(table.chainId, table.spoke, table.debtReserveId),
  }),
);
