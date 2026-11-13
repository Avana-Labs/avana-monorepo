// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Hubs, the Spokes each Hub lists and the credit lines between Hubs, as last reported by events. Every table is keyed
// by chain and Hub (the funding Hub for a line); amounts are the Hub's or the registry's own figures, never summed here.

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

/** A Hub-to-Hub line (`CrossHubLineSet`): the cap a CDP Spoke of another Hub may draw on the funding Hub's asset. */
export const crossHubLine = onchainTable(
  "cross_hub_line",
  (t) => ({
    chainId: t.integer().notNull(),
    fundingHub: t.hex().notNull(),
    asset: t.hex().notNull(),
    spoke: t.hex().notNull(),
    cap: t.bigint().notNull(),
    /** Σ caps of every cross-Hub line on this funding Hub asset after the change. */
    total: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.fundingHub, table.asset, table.spoke] }) }),
);

/** Whether Hub-to-Hub lines are open on the chain (`CrossHubLinesEnabledSet`); one row per chain. */
export const crossHubConfig = onchainTable("cross_hub_config", (t) => ({
  chainId: t.integer().primaryKey(),
  enabled: t.boolean().notNull(),
  lastBlock: t.bigint().notNull(),
}));

/** The credit line of a Hub asset (`CreditLineSet`): the most every CDP Spoke's draw cap may add up to. */
export const creditLine = onchainTable(
  "credit_line",
  (t) => ({
    chainId: t.integer().notNull(),
    hub: t.hex().notNull(),
    asset: t.hex().notNull(),
    line: t.bigint().notNull(),
    /** Σ draw caps recorded against the line. */
    sum: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.hub, table.asset] }) }),
);

/** One Spoke's draw cap recorded against a Hub asset's credit line (`CreditLineRecorded`). */
export const creditLineSpoke = onchainTable(
  "credit_line_spoke",
  (t) => ({
    chainId: t.integer().notNull(),
    hub: t.hex().notNull(),
    asset: t.hex().notNull(),
    spoke: t.hex().notNull(),
    drawCap: t.bigint().notNull(),
    lastBlock: t.bigint().notNull(),
  }),
  (table) => ({ pk: primaryKey({ columns: [table.chainId, table.hub, table.asset, table.spoke] }) }),
);
