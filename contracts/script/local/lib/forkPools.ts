// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The fork-pools step: on a forked chain, make each real pool a listing uses able to serve the LPOracle's TWAP check
// before the listing runs. The check (ClLPVaultMarkets.consistencyDeviation) needs the pool's observation cardinality
// at least LPPriceMath.minObservations(window, blockTime) = ceil(window / blockTime) + 1, and `observe(window)` to
// succeed, i.e. an observation at least `window` seconds old. Many real pools have a smaller buffer (a few slots).
//
// For each pool: raise `cardinalityNext` to the need, then write observations, one per block, `blockTime` apart, until
// the cardinality has grown to the need and `observe(window)` succeeds. Cardinality only grows when the observation
// index wraps onto the new slots, so a pool needs (cardinality - index) writes to grow, then up to `need` more to span
// the window. Local only: on a real network an operator raises and fills the pools before listing (the Hub plan's
// checklist says so).
//
// The chain is reached through `PoolIo`, so the planning runs in tests against a model of the pool's oracle;
// `rpcPoolIo` is the adapter for an anvil fork.

import { type Address, decodeFunctionResult, encodeFunctionData, parseAbi } from "viem";

export interface PoolState {
  observationIndex: number;
  observationCardinality: number;
  observationCardinalityNext: number;
}

/** What fork-pools needs from the chain, per pool. */
export interface PoolIo {
  state(pool: Address): Promise<PoolState>;
  /** `increaseObservationCardinalityNext(next)`. */
  raise(pool: Address, next: number): Promise<void>;
  /** Writes one observation: a swap in a new block, `blockTime` seconds after the last. */
  write(pool: Address): Promise<void>;
  /** Whether `observe([window, 0])` succeeds. */
  observeOk(pool: Address, window: number): Promise<boolean>;
}

export interface PoolOutcome {
  pool: Address;
  need: number;
  before: PoolState;
  after: PoolState;
  raised: boolean;
  writes: number;
}

/** LPPriceMath.minObservations: the observations a TWAP over `window` needs at `blockTime` seconds per block. */
export function minObservations(window: number, blockTime: number): number {
  if (!(window > 0) || !(blockTime > 0)) throw new Error(`window ${window} and block time ${blockTime} must be positive`);
  return Math.ceil(window / blockTime) + 1;
}

/** The most slots one `increaseObservationCardinalityNext` adds: `Oracle.grow` writes each new slot (about 22,200 gas),
 * so one call for 750 slots would reach a network's 16,777,216 per-transaction gas cap. */
export const MAX_GROW_STEP = 500;

/** The `cardinalityNext` of each grow transaction from `current` to `target`, at most `MAX_GROW_STEP` apart; none
 * when `current` already reaches `target`. */
export function growSteps(current: number, target: number): number[] {
  const out: number[] = [];
  for (let n = current; n < target; ) out.push((n = Math.min(target, n + MAX_GROW_STEP)));
  return out;
}

/** Writes until the cardinality reaches `target` (the index must wrap onto the new slots); 0 when it already has. */
export function writesToGrow(s: PoolState, target: number): number {
  if (s.observationCardinality >= target) return 0;
  return s.observationCardinality - s.observationIndex;
}

/** The most writes fork-pools may make on a pool: grow, then a full window of observations. */
export function maxWrites(s: PoolState, need: number): number {
  return writesToGrow({ ...s, observationCardinalityNext: Math.max(s.observationCardinalityNext, need) }, need) + need;
}

/** Raises and fills one pool; throws when it cannot reach the need within `maxWrites`. */
export async function fillPool(io: PoolIo, pool: Address, window: number, blockTime: number, log: (s: string) => void = () => {}): Promise<PoolOutcome> {
  const need = minObservations(window, blockTime);
  const before = await io.state(pool);
  if (before.observationCardinality >= need && (await io.observeOk(pool, window))) return { pool, need, before, after: before, raised: false, writes: 0 };
  const raised = before.observationCardinalityNext < need;
  for (const next of growSteps(before.observationCardinalityNext, need)) await io.raise(pool, next);
  const limit = maxWrites(before, need);
  log(`${pool}: cardinality ${before.observationCardinality} (next ${before.observationCardinalityNext}), need ${need}: at most ${limit} observations`);
  let writes = 0;
  let s = await io.state(pool);
  while (s.observationCardinality < need || !(await io.observeOk(pool, window))) {
    if (writes >= limit) throw new Error(`${pool}: cardinality ${s.observationCardinality} of ${need} after ${writes} observations`);
    await io.write(pool);
    writes++;
    s = await io.state(pool);
  }
  return { pool, need, before, after: s, raised, writes };
}

/** Every pool, one after the other (the writes advance the chain's clock, which all pools share). */
export async function fillPools(io: PoolIo, pools: readonly Address[], window: number, blockTime: number, log?: (s: string) => void): Promise<PoolOutcome[]> {
  const out: PoolOutcome[] = [];
  for (const p of [...new Set(pools.map((x) => x.toLowerCase() as Address))]) out.push(await fillPool(io, p, window, blockTime, log));
  return out;
}

// ---- anvil fork adapter ----------------------------------------------------------------------------------------------

export type PoolKind = "uniswap-v3" | "slipstream";

export interface RpcPoolIoArgs {
  rpc: (method: string, params: unknown[]) => Promise<any>;
  /** Sends a transaction from the funded trader (a keystore signer) and waits for it. */
  send: (to: Address, data: `0x${string}`) => Promise<void>;
  trader: Address;
  blockTime: number;
  /** The swap router of each kind (the venue's own: SwapRouter, Slipstream's SwapRouter). */
  routers: Record<PoolKind, Address>;
  kindOf: (pool: Address) => PoolKind;
}

const POOL = parseAbi([
  "function token0() view returns (address)",
  "function token1() view returns (address)",
  "function fee() view returns (uint24)",
  "function tickSpacing() view returns (int24)",
  "function increaseObservationCardinalityNext(uint16 observationCardinalityNext)",
  "function observe(uint32[] secondsAgos) view returns (int56[] tickCumulatives, uint160[] secondsPerLiquidityCumulativeX128s)",
]);
const SLOT0 = {
  "uniswap-v3": parseAbi(["function slot0() view returns (uint160, int24, uint16, uint16, uint16, uint8, bool)"]),
  slipstream: parseAbi(["function slot0() view returns (uint160, int24, uint16, uint16, uint16, bool)"]),
};
const ERC20 = parseAbi(["function decimals() view returns (uint8)", "function balanceOf(address) view returns (uint256)", "function approve(address, uint256) returns (bool)"]);
const ROUTER = {
  "uniswap-v3": parseAbi([
    "struct P { address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96; }",
    "function exactInputSingle(P params) payable returns (uint256)",
  ]),
  slipstream: parseAbi([
    "struct P { address tokenIn; address tokenOut; int24 tickSpacing; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96; }",
    "function exactInputSingle(P params) payable returns (uint256)",
  ]),
};

/** `PoolIo` over JSON-RPC on an anvil fork (automine): reads with eth_call, writes from the trader, one block per
 * observation. */
export function rpcPoolIo(a: RpcPoolIoArgs): PoolIo {
  const call = async (to: Address, abi: any, functionName: string, args: unknown[] = []) => {
    const data = encodeFunctionData({ abi, functionName, args });
    return decodeFunctionResult({ abi, functionName, data: await a.rpc("eth_call", [{ to, data }, "latest"]) });
  };
  const approved = new Set<string>();
  const owed = new Map<string, bigint>();
  const facts = new Map<string, { t0: Address; t1: Address; param: number; amount0: bigint }>();
  const factsOf = async (pool: Address) => {
    let f = facts.get(pool);
    if (f) return f;
    const kind = a.kindOf(pool);
    const t0 = (await call(pool, POOL, "token0")) as Address;
    const t1 = (await call(pool, POOL, "token1")) as Address;
    const param = Number(await call(pool, POOL, kind === "slipstream" ? "tickSpacing" : "fee"));
    // A swap of a ten-thousandth of a token0: enough to write an observation, too small to move a real pool.
    const amount0 = 10n ** BigInt(Number(await call(t0, ERC20, "decimals"))) / 10_000n || 1n;
    f = { t0, t1, param, amount0 };
    facts.set(pool, f);
    return f;
  };
  const swap = async (pool: Address, tokenIn: Address, tokenOut: Address, amountIn: bigint) => {
    const kind = a.kindOf(pool);
    const router = a.routers[kind];
    if (!approved.has(`${router}:${tokenIn}`)) {
      await a.send(tokenIn, encodeFunctionData({ abi: ERC20, functionName: "approve", args: [router, 2n ** 256n - 1n] }));
      approved.add(`${router}:${tokenIn}`);
    }
    const { param } = await factsOf(pool);
    const block = await a.rpc("eth_getBlockByNumber", ["latest", false]);
    const params = {
      tokenIn,
      tokenOut,
      ...(kind === "slipstream" ? { tickSpacing: param } : { fee: param }),
      recipient: a.trader,
      deadline: BigInt(block.timestamp) + 3600n,
      amountIn,
      amountOutMinimum: 0n,
      sqrtPriceLimitX96: 0n,
    };
    await a.send(router, encodeFunctionData({ abi: ROUTER[kind] as any, functionName: "exactInputSingle", args: [params] }));
  };
  return {
    async state(pool) {
      const s = (await call(pool, SLOT0[a.kindOf(pool)], "slot0")) as readonly unknown[];
      return { observationIndex: Number(s[2]), observationCardinality: Number(s[3]), observationCardinalityNext: Number(s[4]) };
    },
    async raise(pool, next) {
      await a.send(pool, encodeFunctionData({ abi: POOL, functionName: "increaseObservationCardinalityNext", args: [next] }));
    },
    async write(pool) {
      // One swap, in its own block `blockTime` after the last, writes one observation. The direction alternates, the
      // way back swapping what the way out bought, so the trader's balances and the pool's price stay where they were.
      const { t0, t1, amount0 } = await factsOf(pool);
      const last = await a.rpc("eth_getBlockByNumber", ["latest", false]);
      await a.rpc("evm_setNextBlockTimestamp", [Number(BigInt(last.timestamp)) + a.blockTime]);
      const back = owed.get(pool);
      if (back) {
        owed.delete(pool);
        await swap(pool, t1, t0, back);
      } else {
        const before = BigInt((await call(t1, ERC20, "balanceOf", [a.trader])) as bigint);
        await swap(pool, t0, t1, amount0);
        const got = BigInt((await call(t1, ERC20, "balanceOf", [a.trader])) as bigint) - before;
        if (got > 0n) owed.set(pool, got);
      }
    },
    async observeOk(pool, window) {
      try {
        await call(pool, POOL, "observe", [[window, 0]]);
        return true;
      } catch {
        return false;
      }
    },
  };
}

