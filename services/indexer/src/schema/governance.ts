// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Pause state, address freezes, timelock operations, implementations, roles and Coverage Spoke balances.

import { index, onchainTable, primaryKey } from "ponder";

export const pauseState = onchainTable(
  "pause_state",
  (t) => ({
    chainId: t.integer().notNull(),
    hub: t.hex().notNull(),
    /** None, Frozen or Paused. */
    state: t.text().notNull(),
    /** None, General or MintPathSuspect. */
    reason: t.text().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.hub] }) }),
);

export const frozenAddress = onchainTable(
  "frozen_address",
  (t) => ({
    chainId: t.integer().notNull(),
    account: t.hex().notNull(),
    frozen: t.boolean().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.account] }) }),
);

/** OpenZeppelin TimelockController operations. Expiry emits no event: `expiresAt = readyAt + GRACE_PERIOD` (REQ-ACCESS-108). */
export const timelockOperation = onchainTable(
  "timelock_operation",
  (t) => ({
    chainId: t.integer().notNull(),
    operationId: t.hex().notNull(),
    /** Scheduled, Executed, Cancelled or Cleaned (ExpiredOperationCleaned). */
    status: t.text().notNull(),
    /** One entry per call of a batch: target, value (decimal string), data. */
    calls: t.json().notNull(),
    readyAt: t.bigint().notNull(),
    expiresAt: t.bigint().notNull(),
    scheduledBlock: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.operationId] }),
    statusIdx: index().on(table.chainId, table.status),
  }),
);

/** ERC-1967 implementation of each upgradeable contract, from `Upgraded`; the keeper's code check reads the slot itself. */
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

export const roleMember = onchainTable(
  "role_member",
  (t) => ({
    chainId: t.integer().notNull(),
    contract: t.hex().notNull(),
    role: t.hex().notNull(),
    account: t.hex().notNull(),
    granted: t.boolean().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.contract, table.role, table.account] }) }),
);

/** Funded balance of each Coverage Spoke after its last event (`balanceAfter`). */
export const coverageBalance = onchainTable(
  "coverage_balance",
  (t) => ({
    chainId: t.integer().notNull(),
    coverageSpoke: t.hex().notNull(),
    balance: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.coverageSpoke] }) }),
);
