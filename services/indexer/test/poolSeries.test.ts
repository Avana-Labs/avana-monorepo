// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Pool series from Swap, Mint and Burn: volumes and fees per bucket, the last price, and partial buckets of two
// adjacent history ranges combining into the bucket a single range gives.

import { describe, expect, it } from "vitest";
import { mergeValues } from "@avana/services-common";
import { type PoolLog, aggregatePoolLogs, interpolateTimestamp, swapValues } from "../src/lib/poolSeries.ts";

const H = 1_767_225_600; // 2026-01-01T00:00:00Z
const POOL = "0x00000000000000000000000000000000000000aa";

const swap = (block: bigint, logIndex: number, timestamp: number, amount0: bigint, amount1: bigint, tick: number): PoolLog => ({
  kind: "Swap",
  blockNumber: block,
  logIndex,
  timestamp,
  args: { amount0, amount1, sqrtPriceX96: 79228162514264337593543950336n + BigInt(tick), liquidity: 10n ** 18n, tick },
});

describe("swap values", () => {
  it("charges the fee on the input side only, rounded down", () => {
    // 1,000,000 USDC in at 100 pips (0.01 %) → 100 USDC of fee; 999,950 USDT out.
    const v = swapValues({ amount0: 1_000_000_000_000n, amount1: -999_950_000_000n, sqrtPriceX96: 1n, liquidity: 1n, tick: -1 }, 100);
    expect(v).toMatchObject({ volume0: "1000000000000", volume1: "999950000000", fees0: "100000000", fees1: "0", swaps: "1", tick: "-1" });
    expect(swapValues({ amount0: -5n, amount1: 199n, sqrtPriceX96: 1n, liquidity: 1n, tick: 0 }, 500).fees1).toBe("0");
  });
});

describe("bucket aggregation", () => {
  const logs: PoolLog[] = [
    swap(100n, 0, H + 10, 1_000n, -999n, 1),
    swap(101n, 3, H + 3_000, -2_000n, 2_002n, -2),
    { kind: "Mint", blockNumber: 101n, logIndex: 1, timestamp: H + 3_000, args: { amount: 500n, amount0: 1n, amount1: 1n } },
    swap(400n, 0, H + 3_700, 10n, -10n, 4),
  ];

  it("sums volumes and fees per hour and per day and keeps the last swap's price", () => {
    const records = aggregatePoolLogs(1, POOL, logs, 100);
    const hour0 = records.find((r) => r.resolution === "hour" && r.bucketStart === H)!;
    expect(hour0.values).toMatchObject({ volume0: "3000", volume1: "3001", swaps: "2", mints: "1", tick: "-2", tickHigh: "1", tickLow: "-2" });
    expect(hour0.blockNumber).toBe("101");
    const day = records.find((r) => r.resolution === "day")!;
    expect(day.values).toMatchObject({ volume0: "3010", swaps: "3", tick: "4", tickHigh: "4", tickLow: "-2" });
    expect(records.filter((r) => r.resolution === "hour").map((r) => r.bucketStart)).toEqual([H, H + 3_600]);
  });

  it("orders logs by block and log index whatever order they arrive in", () => {
    const shuffled = [logs[3]!, logs[1]!, logs[0]!, logs[2]!];
    expect(aggregatePoolLogs(1, POOL, shuffled, 100)).toEqual(aggregatePoolLogs(1, POOL, logs, 100));
  });

  it("gives the same bucket from two adjacent ranges as from one range", () => {
    const whole = aggregatePoolLogs(1, POOL, logs, 100);
    const first = aggregatePoolLogs(1, POOL, logs.slice(0, 1), 100);
    const second = aggregatePoolLogs(1, POOL, logs.slice(1), 100);
    for (const w of whole) {
      const a = first.find((r) => r.resolution === w.resolution && r.bucketStart === w.bucketStart);
      const b = second.find((r) => r.resolution === w.resolution && r.bucketStart === w.bucketStart);
      const merged = a && b ? mergeValues("pool", a.values, b.values) : (a ?? b)!.values;
      expect(merged).toEqual(w.values);
    }
  });
});

describe("timestamp interpolation", () => {
  it("is exact on a fixed block time and clamps outside the anchors", () => {
    const lo = { number: 1_000n, timestamp: H };
    const hi = { number: 2_800n, timestamp: H + 3_600 };
    expect(interpolateTimestamp(1_900n, lo, hi)).toBe(H + 1_800);
    expect(interpolateTimestamp(999n, lo, hi)).toBe(H);
    expect(interpolateTimestamp(3_000n, lo, hi)).toBe(H + 3_600);
  });
});
