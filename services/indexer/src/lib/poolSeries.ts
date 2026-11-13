// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Pool series values from concentrated-liquidity Swap, Mint and Burn logs. Shared by the live handlers and the
// history endpoint, so a bucket built from the history and one built live hold the same numbers for the same logs.
// Amounts stay in each token's base units; Convex values them with the market's token prices.

import { type DecimalString, type Resolution, type SeriesRecord, bucketStart, mergeValues, scopeKey } from "@avana/services-common";

export interface SwapArgs {
  readonly amount0: bigint;
  readonly amount1: bigint;
  readonly sqrtPriceX96: bigint;
  readonly liquidity: bigint;
  readonly tick: number;
}

export interface LiquidityArgs {
  readonly amount: bigint;
  readonly amount0: bigint;
  readonly amount1: bigint;
}

const abs = (x: bigint): bigint => (x < 0n ? -x : x);
const s = (x: bigint | number): DecimalString => x.toString(10);

/**
 * One swap: volume on both sides, the fee on the input side (the positive amount, which includes the fee) at
 * `feePips` / 10⁶ rounded down, and the price, tick and active liquidity after it. The pool rounds each step's fee
 * up, so this can be below the pool's fee by at most one unit per tick crossed.
 */
export function swapValues(a: SwapArgs, feePips: number): Record<string, DecimalString> {
  const fee = (amountIn: bigint) => (amountIn > 0n ? (amountIn * BigInt(feePips)) / 1_000_000n : 0n);
  return {
    volume0: s(abs(a.amount0)),
    volume1: s(abs(a.amount1)),
    fees0: s(fee(a.amount0)),
    fees1: s(fee(a.amount1)),
    swaps: "1",
    sqrtPriceX96: s(a.sqrtPriceX96),
    liquidity: s(a.liquidity),
    tick: s(a.tick),
    tickHigh: s(a.tick),
    tickLow: s(a.tick),
  };
}

export function mintValues(a: LiquidityArgs): Record<string, DecimalString> {
  return { mints: "1", liquidityAdded: s(a.amount) };
}

export function burnValues(a: LiquidityArgs): Record<string, DecimalString> {
  return { burns: "1", liquidityRemoved: s(a.amount) };
}

export type PoolLog =
  | { readonly kind: "Swap"; readonly blockNumber: bigint; readonly logIndex: number; readonly timestamp: number; readonly args: SwapArgs }
  | { readonly kind: "Mint" | "Burn"; readonly blockNumber: bigint; readonly logIndex: number; readonly timestamp: number; readonly args: LiquidityArgs };

/** Values one log adds to its pool's bucket. */
export function poolLogValues(log: PoolLog, feePips: number): Record<string, DecimalString> {
  if (log.kind === "Swap") return swapValues(log.args, feePips);
  return log.kind === "Mint" ? mintValues(log.args) : burnValues(log.args);
}

/**
 * Hourly and daily buckets of a block range's logs, applied in (block, logIndex) order so `last` keeps the last
 * swap. A bucket cut by the range's edge is partial; the merge rules make two partial buckets of adjacent ranges
 * combine into the whole bucket.
 */
export function aggregatePoolLogs(chainId: number, pool: string, logs: readonly PoolLog[], feePips: number): SeriesRecord[] {
  const ordered = [...logs].sort((a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1));
  const buckets = new Map<string, { resolution: Resolution; start: number; block: bigint; values: Record<string, DecimalString> }>();
  for (const log of ordered) {
    const values = poolLogValues(log, feePips);
    for (const resolution of ["hour", "day"] as const) {
      const start = bucketStart(log.timestamp, resolution);
      const id = `${resolution}:${start}`;
      const prev = buckets.get(id);
      buckets.set(id, { resolution, start, block: log.blockNumber, values: prev ? mergeValues("pool", prev.values, values) : values });
    }
  }
  const key = scopeKey(chainId, pool);
  return [...buckets.values()]
    .sort((a, b) => a.start - b.start || a.resolution.localeCompare(b.resolution))
    .map((b) => ({ chainId, scopeKind: "pool", scopeKey: key, resolution: b.resolution, bucketStart: b.start, blockNumber: s(b.block), values: b.values }));
}

/**
 * Timestamps of blocks between two known blocks by linear interpolation. Exact on chains with a fixed block time
 * and no missed slots; on Ethereum a missed slot can move a log by one slot, which matters only for a log within
 * seconds of an hour boundary.
 */
export function interpolateTimestamp(block: bigint, lo: { number: bigint; timestamp: number }, hi: { number: bigint; timestamp: number }): number {
  if (block <= lo.number) return lo.timestamp;
  if (block >= hi.number) return hi.timestamp;
  const span = Number(hi.number - lo.number);
  return lo.timestamp + Math.floor(((hi.timestamp - lo.timestamp) * Number(block - lo.number)) / span);
}
