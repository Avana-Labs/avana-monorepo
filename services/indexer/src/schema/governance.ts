// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Aave Hub and Spoke implementations, and the funded balance of each loss layer.

import { onchainTable, primaryKey } from "ponder";

/** ERC-1967 implementation of each Aave Hub and Spoke proxy, from `Upgraded`. Avana's core contracts are not upgradeable. */
export const implementation = onchainTable(
  "implementation",
  (t) => ({
    chainId: t.integer().notNull(),
    proxy: t.hex().notNull(),
    implementation: t.hex().notNull(),
    changedBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.proxy] }) }),
);

/** Funded balance of each First-Loss Reserve and DAO deficit offset after its last event (`balanceAfter`). */
export const coverageBalance = onchainTable(
  "coverage_balance",
  (t) => ({
    chainId: t.integer().notNull(),
    firstLossReserve: t.hex().notNull(),
    balance: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.firstLossReserve] }) }),
);
