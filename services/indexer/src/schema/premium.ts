// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Aave V4 risk premiums of Avana accounts and the collateral risk of each Spoke reserve, for the list of proxies the
// Aave DAO's refresh payload passes to `updateUserRiskPremium` after a `collateralRisk` change (services/README.md).

import { index, onchainTable, primaryKey } from "ponder";

/** The last `UpdateUserRiskPremium` of an attributed account (key as `account`). */
export const accountPremium = onchainTable(
  "account_premium",
  (t) => ({
    chainId: t.integer().notNull(),
    spoke: t.hex().notNull(),
    proxy: t.hex().notNull(),
    /** The Spoke's user risk premium as emitted (Aave V4 units). */
    riskPremium: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
    lastLogIndex: t.integer().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.spoke, table.proxy] }) }),
);

/**
 * Each Spoke reserve's configuration after its last `UpdateReserveConfig`. `riskChangedBlock` and `riskChangedLogIndex`
 * mark the last log that changed `collateralRisk` from a previous value; a reserve's first configuration is not a
 * change, because no account held a premium computed under another value.
 */
export const reserveConfig = onchainTable(
  "reserve_config",
  (t) => ({
    chainId: t.integer().notNull(),
    spoke: t.hex().notNull(),
    reserveId: t.bigint().notNull(),
    collateralRisk: t.integer().notNull(),
    paused: t.boolean().notNull(),
    frozen: t.boolean().notNull(),
    borrowable: t.boolean().notNull(),
    riskChangedBlock: t.bigint(),
    riskChangedLogIndex: t.integer(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({
    pk: primaryKey({ columns: [table.chainId, table.spoke, table.reserveId] }),
    spokeIdx: index().on(table.chainId, table.spoke),
  }),
);
