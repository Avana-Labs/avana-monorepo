// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Hubs, the Spokes each Hub lists and the CDP Spokes the MarketRegistry approves, as last reported by events. Every
// table is keyed by chain and Hub or Spoke.

import { onchainTable, primaryKey } from "ponder";

/** Every Hub the MarketRegistry records (`HubRecorded`), with its risk tier. */
export const hub = onchainTable(
  "hub",
  (t) => ({
    chainId: t.integer().notNull(),
    hub: t.hex().notNull(),
    tier: t.integer().notNull(),
    recordedBlock: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.hub] }) }),
);

/** Every Spoke a followed Hub adds to one of its assets (`AddSpoke`): Lend, CDP, Coverage and fee receiver alike. */
export const hubSpoke = onchainTable(
  "hub_spoke",
  (t) => ({
    chainId: t.integer().notNull(),
    hub: t.hex().notNull(),
    assetId: t.bigint().notNull(),
    spoke: t.hex().notNull(),
    addedBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.hub, table.assetId, table.spoke] }) }),
);

/** Every CDP Spoke the MarketRegistry approves (`SpokeApproved`), with its home Hub. */
export const cdpSpoke = onchainTable(
  "cdp_spoke",
  (t) => ({
    chainId: t.integer().notNull(),
    spoke: t.hex().notNull(),
    hub: t.hex().notNull(),
    integrationId: t.integer().notNull(),
    implementation: t.hex().notNull(),
    aaveOracle: t.hex().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.spoke] }) }),
);
