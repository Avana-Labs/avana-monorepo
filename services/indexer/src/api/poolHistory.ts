// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Pool history before listing (EXPORT.md, "Pool history"). Ponder follows a pool only from the block that announced
// it, so the swaps, mints and burns before that block are read here on request, over the indexer's RPC, and
// aggregated with the same function the live handlers use. Only finalized blocks before the listing are served,
// so the answer for a range never changes and Convex can merge adjacent ranges bucket by bucket.

import { publicClients } from "ponder:api";
import { type SeriesRecord, chainById } from "@avana/services-common";
import { clPoolAbi } from "@avana/services-common/views";
import type { AbiEvent } from "viem";
import { db } from "ponder:api";
import schema from "ponder:schema";
import { and, eq } from "ponder";
import { type PoolLog, aggregatePoolLogs, interpolateTimestamp } from "../lib/poolSeries.ts";

/** Largest range one request covers: a day of Base blocks. */
export const POOL_HISTORY_MAX_BLOCKS = 50_000n;
const FIRST_CHUNK = 10_000n;

export interface PoolHistory {
  readonly chainId: number;
  readonly pool: `0x${string}`;
  readonly fromBlock: string;
  readonly toBlock: string;
  readonly feePips: number;
  readonly records: readonly SeriesRecord[];
}

export class PoolHistoryRefused extends Error {}

const events = clPoolAbi.filter((item): item is Extract<(typeof clPoolAbi)[number], AbiEvent> => item.type === "event");

/** Returns the buckets of `fromBlock..toBlock`; refuses a range that reaches the listing block or finality. */
export async function readPoolHistory(chainId: number, pool: `0x${string}`, fromBlock: bigint, toBlock: bigint): Promise<PoolHistory> {
  const client = publicClients[chainById(chainId).key];
  if (!client) throw new PoolHistoryRefused(`chain ${chainId} is not indexed`);
  if (toBlock < fromBlock || toBlock - fromBlock + 1n > POOL_HISTORY_MAX_BLOCKS) throw new PoolHistoryRefused(`range must hold 1..${POOL_HISTORY_MAX_BLOCKS} blocks`);
  const [row] = await db.select().from(schema.ammPool).where(and(eq(schema.ammPool.chainId, chainId), eq(schema.ammPool.pool, pool)));
  if (!row) throw new PoolHistoryRefused(`pool ${pool} is not listed on chain ${chainId}`);
  if (toBlock >= row.listedBlock) throw new PoolHistoryRefused(`blocks from ${row.listedBlock} on are in the live series`);
  const finalized = await client.getBlock({ blockTag: "finalized" });
  if (toBlock > finalized.number) throw new PoolHistoryRefused("range is not finalized");

  // The fee at the end of the range; a dynamic fee is taken as constant over one request.
  const feePips = Number(await client.readContract({ address: pool, abi: clPoolAbi, functionName: "fee", blockNumber: toBlock }));
  const blockTime = BigInt(chainById(chainId).blockTimeSeconds);
  const anchorStep = 3_600n / blockTime;
  const anchors = new Map<bigint, number>();
  const anchor = async (n: bigint) => {
    const hit = anchors.get(n);
    if (hit !== undefined) return hit;
    const t = Number((await client.getBlock({ blockNumber: n })).timestamp);
    anchors.set(n, t);
    return t;
  };

  const logs: PoolLog[] = [];
  let chunk = FIRST_CHUNK;
  for (let start = fromBlock; start <= toBlock; ) {
    const end = start + chunk - 1n < toBlock ? start + chunk - 1n : toBlock;
    let found;
    try {
      found = await client.getLogs({ address: pool, events, fromBlock: start, toBlock: end, strict: true });
    } catch (e) {
      if (chunk === 1n) throw e;
      chunk /= 2n; // the provider refused the range: halve it and retry
      continue;
    }
    for (const log of found) {
      const n = log.blockNumber!;
      const lo = n - ((n - fromBlock) % anchorStep);
      const hi = lo + anchorStep > toBlock ? toBlock : lo + anchorStep;
      const timestamp = interpolateTimestamp(n, { number: lo, timestamp: await anchor(lo) }, { number: hi, timestamp: await anchor(hi) });
      const base = { blockNumber: n, logIndex: log.logIndex!, timestamp };
      const args = log.args as unknown as Record<string, bigint | number>;
      if (log.eventName === "Swap") {
        logs.push({ ...base, kind: "Swap", args: { amount0: args.amount0 as bigint, amount1: args.amount1 as bigint, sqrtPriceX96: args.sqrtPriceX96 as bigint, liquidity: args.liquidity as bigint, tick: Number(args.tick) } });
      } else {
        logs.push({ ...base, kind: log.eventName as "Mint" | "Burn", args: { amount: args.amount as bigint, amount0: args.amount0 as bigint, amount1: args.amount1 as bigint } });
      }
    }
    start = end + 1n;
  }
  return { chainId, pool, fromBlock: fromBlock.toString(10), toBlock: toBlock.toString(10), feePips, records: aggregatePoolLogs(chainId, pool, logs, feePips) };
}
