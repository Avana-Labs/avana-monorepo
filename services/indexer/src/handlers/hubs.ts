// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Spokes each Hub lists: Aave Hub `AddSpoke`.
// Each upsert writes the event's values, so a second delivery of a log (aaveSources.ts) leaves the row as it is.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { AAVE_HUB_SOURCES } from "../config/aaveSources.ts";
import { recordLog } from "../lib/record.ts";

for (const source of AAVE_HUB_SOURCES) {
  ponder.on(`${source}:AddSpoke`, async ({ event, context }) => {
    const p = await recordLog(event, context, "AaveHub.AddSpoke");
    await context.db
      .insert(schema.hubSpoke)
      .values({ chainId: p.chainId, hub: event.log.address, assetId: event.args.assetId, spoke: event.args.spoke, addedBlock: p.blockNumber })
      .onConflictDoNothing();
  });
}
