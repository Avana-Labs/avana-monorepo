// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Spokes each followed Hub lists, as last reported by its `AddSpoke` events. Keyed by chain, Hub, asset and
// Spoke.

import { onchainTable, primaryKey } from "ponder";

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
