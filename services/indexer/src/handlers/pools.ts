// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Swap, Mint and Burn of every listed market's pool, from the block of its `MarketRegistered` on, into the pool's
// hourly and daily series. Pool logs are not written to `event_log`: a busy stable pool emits thousands of swaps a
// day, and the app reads them only as series. Earlier history comes from the pool-history endpoint (EXPORT.md).

import { scopeKey } from "@avana/services-common";
import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { burnValues, mintValues, swapValues } from "../lib/poolSeries.ts";
import { writeObservation } from "../lib/seriesWrite.ts";

ponder.on("AmmPool:Swap", async ({ event, context }) => {
  const chainId = context.chain.id;
  const pool = event.log.address.toLowerCase() as `0x${string}`;
  const row = await context.db.find(schema.ammPool, { chainId, pool });
  if (!row) throw new Error(`swap on pool ${pool} before its MarketRegistered row`);
  const { amount0, amount1, sqrtPriceX96, liquidity, tick } = event.args;
  await writeObservation(context, {
    chainId,
    kind: "pool",
    key: scopeKey(chainId, pool),
    timestamp: Number(event.block.timestamp),
    blockNumber: event.block.number,
    values: swapValues({ amount0, amount1, sqrtPriceX96, liquidity, tick: Number(tick) }, row.feePips),
  });
});

for (const [name, values] of [["Mint", mintValues], ["Burn", burnValues]] as const) {
  ponder.on(`AmmPool:${name}`, async ({ event, context }) => {
    const chainId = context.chain.id;
    const pool = event.log.address.toLowerCase();
    const { amount, amount0, amount1 } = event.args;
    await writeObservation(context, {
      chainId,
      kind: "pool",
      key: scopeKey(chainId, pool),
      timestamp: Number(event.block.timestamp),
      blockNumber: event.block.number,
      values: values({ amount, amount0, amount1 }),
    });
  });
}
