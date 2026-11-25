// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Swap, ModifyLiquidity and Donate of the chain's Uniswap v4 PoolManager, for pools a market lists by poolId
// (`amm_pool_id`), into the same pool series fields as a concentrated-liquidity pool, keyed `chainId:poolId`. Logs of
// other pools are dropped. Like pool logs, these are not written to `event_log`.

import { type DecimalString, scopeKey } from "@avana/services-common";
import { type Context, ponder } from "ponder:registry";
import schema from "ponder:schema";
import { donateValues, liquidityDeltaValues, poolManagerSwapArgs, swapValues } from "../lib/poolSeries.ts";
import { writeObservation } from "../lib/seriesWrite.ts";

type Event = { args: { id: `0x${string}` }; block: { number: bigint; timestamp: bigint } };

/** Writes `values` into the pool's series when a market lists the pool; returns without a write otherwise. */
async function write(event: Event, context: Context, values: () => Record<string, DecimalString> | null): Promise<void> {
  const chainId = context.chain.id;
  const poolId = event.args.id.toLowerCase() as `0x${string}`;
  const row = await context.db.find(schema.ammPoolId, { chainId, poolId });
  if (!row) return;
  const v = values();
  if (!v) return;
  await writeObservation(context, {
    chainId,
    kind: "pool",
    key: scopeKey(chainId, poolId),
    timestamp: Number(event.block.timestamp),
    blockNumber: event.block.number,
    values: v,
  });
}

ponder.on("UniswapV4PoolManager:Swap", async ({ event, context }) => {
  const { amount0, amount1, sqrtPriceX96, liquidity, tick, fee } = event.args;
  await write(event, context, () => swapValues(poolManagerSwapArgs({ amount0, amount1, sqrtPriceX96, liquidity, tick: Number(tick) }), Number(fee)));
});

ponder.on("UniswapV4PoolManager:ModifyLiquidity", async ({ event, context }) => {
  await write(event, context, () => liquidityDeltaValues(event.args.liquidityDelta));
});

ponder.on("UniswapV4PoolManager:Donate", async ({ event, context }) => {
  await write(event, context, () => donateValues(event.args.amount0, event.args.amount1));
});
