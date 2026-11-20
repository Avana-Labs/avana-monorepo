// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Pools keyed by identifier (a Uniswap v4 PoolId inside the chain's PoolManager): a pool a Uniswap v4 integration's
// RiskModule lists is followed by its PoolId, its PoolManager logs feed the same pool series fields as a
// concentrated-liquidity pool, and logs of pools no market lists write nothing.

import { describe, expect, it } from "vitest";
import schema from "ponder:schema";
import { type LogSpec, Run, addr } from "./harness/run.ts";
import { V3, V4 } from "./harness/manifest.ts";

const MANAGER = addr(0x4444);
const SPOKE = addr(0xb0);
const POOL_ID = `0x${"7c".repeat(32)}` as const;
const OTHER_ID = `0x${"5e".repeat(32)}` as const;
const SALT = `0x${"00".repeat(32)}` as const;

/** A pool's two markets listed by a RiskModule (v4 by default): MarketListed twice, then PoolListed. */
const listedLogs = (pool: `0x${string}`, fullRange = 1n, block = 10n, riskModule: `0x${string}` = V4.riskModule): LogSpec[] => [
  { source: "RiskModule", event: "MarketListed", args: { marketId: fullRange, pool, kind: 0, bandLower: -887_220, bandUpper: 887_220, unitDecimals: 18 }, address: riskModule, block, logIndex: 0 },
  { source: "RiskModule", event: "MarketListed", args: { marketId: fullRange + 1n, pool, kind: 1, bandLower: -60, bandUpper: 60, unitDecimals: 18 }, address: riskModule, block, logIndex: 1 },
  { source: "RiskModule", event: "PoolListed", args: { pool, spoke: SPOKE, fullRange, customRange: fullRange + 1n, listingTick: 0, ltvBps: 9_000 }, address: riskModule, block, logIndex: 2 },
];

const swap = (id: `0x${string}`, block: bigint, logIndex: number, amount0: bigint, amount1: bigint, tick: number, fee = 500): LogSpec => ({
  source: "UniswapV4PoolManager",
  event: "Swap",
  args: { id, sender: addr(0xc0), amount0, amount1, sqrtPriceX96: 79228162514264337593543950336n, liquidity: 10n ** 18n, tick, fee },
  address: MANAGER,
  block,
  logIndex,
});

const modify = (id: `0x${string}`, block: bigint, logIndex: number, liquidityDelta: bigint): LogSpec => ({
  source: "UniswapV4PoolManager",
  event: "ModifyLiquidity",
  args: { id, sender: addr(0xc0), tickLower: -60, tickUpper: 60, liquidityDelta, salt: SALT },
  address: MANAGER,
  block,
  logIndex,
});

const donate = (id: `0x${string}`, block: bigint, logIndex: number, amount0: bigint, amount1: bigint): LogSpec => ({
  source: "UniswapV4PoolManager",
  event: "Donate",
  args: { id, sender: addr(0xc0), amount0, amount1 },
  address: MANAGER,
  block,
  logIndex,
});

const poolPoints = (run: Run, resolution = "hour") =>
  run.store.rows(schema.seriesPoint).filter((r) => r.scopeKind === "pool" && r.resolution === resolution);

describe("pools keyed by identifier", () => {
  it("follows a pool a Uniswap v4 integration lists by its PoolId, without reading a pool contract", async () => {
    const run = new Run(); // any contract read throws
    await run.deliverAll(listedLogs(POOL_ID));
    expect(run.store.rows(schema.ammPoolId)).toMatchObject([{ chainId: 1, poolId: POOL_ID, integrationId: 3, listedBlock: 10n }]);
    expect(run.store.rows(schema.ammPool)).toEqual([]);
    expect(run.store.rows(schema.market).map((m) => [m.pool, m.kind])).toEqual([
      [POOL_ID, "full-range"],
      [POOL_ID, "custom-range"],
    ]);
  });

  it("follows a pool a concentrated-liquidity integration lists by the address in its key", async () => {
    const run = new Run();
    run.client.readContract = async () => 100;
    await run.deliverAll(listedLogs(`0x${"00".repeat(12)}${addr(0xf5).slice(2)}`, 1n, 10n, V3.riskModule));
    expect(run.store.rows(schema.ammPool)).toMatchObject([{ pool: addr(0xf5), feePips: 100, integrationId: 1 }]);
    expect(run.store.rows(schema.ammPoolId)).toEqual([]);
  });

  it("writes a swap of a listed pool into the pool series under chainId:poolId, the input side negative", async () => {
    const run = new Run();
    // 1,000,000 of currency0 in at 500 pips: the swapper's delta is negative on the input side in v4.
    await run.deliverAll([...listedLogs(POOL_ID), swap(POOL_ID, 11n, 0, -1_000_000n, 999_000n, -3)]);
    const [point] = poolPoints(run);
    expect(point).toMatchObject({ scopeKey: `1:${POOL_ID}`, blockNumber: 11n });
    expect(point!.values).toEqual({
      volume0: "1000000",
      volume1: "999000",
      fees0: "500",
      fees1: "0",
      swaps: "1",
      sqrtPriceX96: "79228162514264337593543950336",
      liquidity: "1000000000000000000",
      tick: "-3",
      tickHigh: "-3",
      tickLow: "-3",
    });
  });

  it("uses each swap's own fee", async () => {
    const run = new Run();
    await run.deliverAll([...listedLogs(POOL_ID), swap(POOL_ID, 11n, 0, 2_000_000n, -1_000_000n, 1, 3_000)]);
    expect(poolPoints(run)[0]!.values).toMatchObject({ fees0: "0", fees1: "3000", volume0: "2000000", volume1: "1000000" });
  });

  it("counts added and removed liquidity and skips a zero-delta call", async () => {
    const run = new Run();
    await run.deliverAll([...listedLogs(POOL_ID), modify(POOL_ID, 11n, 0, 700n), modify(POOL_ID, 11n, 1, -200n), modify(POOL_ID, 11n, 2, 0n)]);
    expect(poolPoints(run)[0]!.values).toEqual({ mints: "1", liquidityAdded: "700", burns: "1", liquidityRemoved: "200" });
  });

  it("adds a donation to the fees of the pool", async () => {
    const run = new Run();
    await run.deliverAll([...listedLogs(POOL_ID), swap(POOL_ID, 11n, 0, -1_000_000n, 999_000n, 0), donate(POOL_ID, 11n, 1, 40n, 7n)]);
    expect(poolPoints(run)[0]!.values).toMatchObject({ fees0: "540", fees1: "7", swaps: "1" });
  });

  it("writes nothing for a pool no market lists", async () => {
    const run = new Run();
    await run.deliverAll([...listedLogs(POOL_ID), swap(OTHER_ID, 11n, 0, -5n, 4n, 0), modify(OTHER_ID, 11n, 1, 9n), donate(OTHER_ID, 11n, 2, 1n, 1n)]);
    expect(run.store.rows(schema.seriesPoint)).toEqual([]);
  });

  it("writes nothing before the market's listing block", async () => {
    const run = new Run();
    await run.deliverAll([swap(POOL_ID, 9n, 0, -5n, 4n, 0), ...listedLogs(POOL_ID)]);
    expect(run.store.rows(schema.seriesPoint)).toEqual([]);
  });

  it("keeps one row when a pool is listed again", async () => {
    const run = new Run();
    await run.deliverAll([...listedLogs(POOL_ID, 1n, 10n), ...listedLogs(POOL_ID, 3n, 12n)]);
    expect(run.store.rows(schema.ammPoolId)).toMatchObject([{ poolId: POOL_ID, listedBlock: 10n }]);
  });
});
