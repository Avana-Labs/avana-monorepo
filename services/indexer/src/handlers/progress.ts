// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Per-chain progress at the realtime head. The source starts at "latest", so a full reindex fetches no extra
// blocks; the row is rolled back with every other table on a reorg.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";

ponder.on("Progress:block", async ({ event, context }) => {
  const row = { blockNumber: event.block.number, blockHash: event.block.hash, blockTimestamp: event.block.timestamp };
  await context.db
    .insert(schema.chainProgress)
    .values({ chainId: context.chain.id, ...row })
    .onConflictDoUpdate(row);
});
