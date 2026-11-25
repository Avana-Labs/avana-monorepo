// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Chart points from stored buckets: pre-listing history merged with live buckets, gaps filled per metric, ranges,
// the live tip, and quick-stat deltas against the snapshot 24 hours earlier.

import { describe, expect, it } from "vitest";
import { combineSources, daySeries, filledBuckets, quickStats, sumOver, valueAt } from "../convex/lib/charts.ts";
import type { MarketSnapshotRow } from "../convex/lib/uiTypes.ts";

const D = 86_400;
const JAN1 = 1_767_225_600;

describe("series buckets", () => {
  it("merges a pool's history and live parts of one bucket by the pool's rules", () => {
    const merged = combineSources("pool", [
      { bucketStart: JAN1, source: "live", values: { volume0: "30", sqrtPriceX96: "200", swaps: "1" } },
      { bucketStart: JAN1, source: "history", values: { volume0: "70", sqrtPriceX96: "100", swaps: "4" } },
    ]);
    expect(merged.get(JAN1)).toEqual({ volume0: "100", sqrtPriceX96: "200", swaps: "5" });
  });

  it("fills a day with no swap with zero volume and the last price", () => {
    const by = new Map([
      [JAN1, { volume0: "5", sqrtPriceX96: "9" }],
      [JAN1 + 2 * D, { volume0: "7", sqrtPriceX96: "8" }],
    ]);
    expect(filledBuckets("pool", by, JAN1, JAN1 + 2 * D, "day").map((b) => b.values)).toEqual([
      { volume0: "5", sqrtPriceX96: "9" },
      { volume0: "0", sqrtPriceX96: "9" },
      { volume0: "7", sqrtPriceX96: "8" },
    ]);
  });

  it("repeats a sampled Hub value through a day with no sample", () => {
    const by = new Map([[JAN1, { added: "10" }]]);
    expect(filledBuckets("hubAsset", by, JAN1, JAN1 + 2 * D, "day").map((b) => b.values.added)).toEqual(["10", "10", "10"]);
  });

  it("cuts ranges to their days and ends at the live value", () => {
    const days = Array.from({ length: 40 }, (_, i) => ({ t: JAN1 + i * D, values: { v: String(i) } }));
    const now = JAN1 + 39 * D + 600;
    const week = daySeries("id", "x", days, (x) => Number(x.v), "1W", now, 99);
    expect(week.points.length).toBe(7);
    expect(week.points.at(-1)).toEqual({ t: "2026-02-09", v: 99 });
    expect(week.points[0]!.v).toBe(33);
    expect(daySeries("id", "x", days, (x) => Number(x.v), "ALL", now, null).points.length).toBe(39);
  });

  it("reads the value as of a time and sums summed metrics over a window", () => {
    const by = new Map([
      [JAN1, { volume0: "5" }],
      [JAN1 + 3_600, { volume0: "6" }],
    ]);
    expect(valueAt(by, JAN1 + 1_000)).toEqual({ volume0: "5" });
    expect(valueAt(by, JAN1 - 1)).toBeNull();
    expect(sumOver(by, "volume0", JAN1, JAN1 + 7_200)).toBe(11n);
  });
});

describe("quick stats", () => {
  const row = (supplied: number, scope: MarketSnapshotRow["scope"] = "lend"): MarketSnapshotRow => ({
    slug: "s",
    scope,
    name: "USDC",
    symbol: "USDC",
    chainId: 1,
    suppliedUsd: supplied,
    borrowedUsd: 3_000_000,
    availableUsd: 7_000_000,
    utilizationPct: 30,
    supplyApyPct: 1.63,
    borrowAprPct: 6,
    tvlUsd: supplied,
    volumeUsd: 0,
    feesUsd: 0,
    reserveFactorPct: 10,
  });

  it("gives the 24 h change in percent of the earlier value", () => {
    const stats = quickStats(row(11_000_000), row(10_000_000));
    expect(stats[0]).toEqual({ id: "supplied", label: "Total Supplied", value: "$11.00M", delta: { value: 10, direction: "up", label: "24h" } });
    expect(stats.find((s) => s.id === "utilization")!.delta.direction).toBe("flat");
    expect(stats.map((s) => s.id)).toEqual(["supplied", "borrowed", "available", "utilization", "supplyApy", "borrowApy", "reserveFactor"]);
  });

  it("labels a pool page in collateral terms and shows no supply APY", () => {
    const { reserveFactorPct: _omit, ...pool } = row(2_000_000, "pool");
    const stats = quickStats(pool, null);
    expect(stats.map((s) => s.label)).toEqual(["Collateral", "Debt Backed", "Cap Headroom", "LTV", "Borrow APR"]);
    expect(stats[0]!.delta.value).toBe(0);
  });
});
