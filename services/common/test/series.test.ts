// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Series bucketing, merge rules and gap filling at their boundaries.

import { describe, expect, it } from "vitest";
import { bucketEnd, bucketStart, bucketsBetween, dayLabel, fillGaps, mergeRule, mergeValues, scopeKey } from "../src/series.ts";

const JAN1 = 1_767_225_600; // 2026-01-01T00:00:00Z

describe("buckets", () => {
  it("puts the first second of a bucket in that bucket and the last second before the next", () => {
    expect(bucketStart(JAN1, "hour")).toBe(JAN1);
    expect(bucketStart(JAN1 + 3_599, "hour")).toBe(JAN1);
    expect(bucketStart(JAN1 + 3_600, "hour")).toBe(JAN1 + 3_600);
    expect(bucketStart(JAN1 + 86_399, "day")).toBe(JAN1);
    expect(bucketStart(JAN1 - 1, "day")).toBe(JAN1 - 86_400);
    expect(bucketStart(BigInt(JAN1 + 7_200), "hour")).toBe(JAN1 + 7_200);
    expect(bucketEnd(JAN1, "day")).toBe(JAN1 + 86_400);
  });

  it("labels days in UTC", () => {
    expect(dayLabel(JAN1)).toBe("2026-01-01");
    expect(dayLabel(JAN1 - 1)).toBe("2025-12-31");
  });

  it("refuses timestamps that are not non-negative integers", () => {
    expect(() => bucketStart(-1, "hour")).toThrow();
    expect(() => bucketStart(1.5, "hour")).toThrow();
  });

  it("lists every bucket between two times, both ends included", () => {
    expect(bucketsBetween(JAN1 + 10, JAN1 + 3 * 3_600 + 5, "hour")).toEqual([JAN1, JAN1 + 3_600, JAN1 + 7_200, JAN1 + 10_800]);
    expect(bucketsBetween(JAN1, JAN1, "day")).toEqual([JAN1]);
  });

  it("builds lower-case scope keys", () => {
    expect(scopeKey(1, "0xABCdef", 3n)).toBe("1:0xabcdef:3");
  });
});

describe("merge rules", () => {
  it("keeps the first sample of a sampled scope", () => {
    expect(mergeRule("hubAsset", "added")).toBe("first");
    expect(mergeValues("hubAsset", { added: "10" }, { added: "12", owed: "3" })).toEqual({ added: "10", owed: "3" });
  });

  it("adds pool volumes and fees, keeps the last price and the extreme ticks", () => {
    const merged = mergeValues(
      "pool",
      { volume0: "100", fees0: "1", sqrtPriceX96: "79228162514264337593543950336", tickHigh: "5", tickLow: "-3", swaps: "2" },
      { volume0: "50", fees0: "2", sqrtPriceX96: "79228162514264337593543950337", tickHigh: "4", tickLow: "-7", swaps: "1" },
    );
    expect(merged).toEqual({ volume0: "150", fees0: "3", sqrtPriceX96: "79228162514264337593543950337", tickHigh: "5", tickLow: "-7", swaps: "3" });
  });

  it("adds integers beyond 2^53 exactly", () => {
    expect(mergeValues("pool", { volume1: "9007199254740993" }, { volume1: "9007199254740993" }).volume1).toBe("18014398509481986");
  });
});

describe("gap filling", () => {
  const p = (h: number, v: string) => ({ t: JAN1 + h * 3_600, v, block: String(100 + h) });

  it("repeats the last sample through missing buckets", () => {
    const out = fillGaps([p(0, "10"), p(3, "13")], "first", JAN1, JAN1 + 4 * 3_600, "hour");
    expect(out.map((x) => x.v)).toEqual(["10", "10", "10", "13", "13"]);
    expect(out[1]!.block).toBe("100");
  });

  it("writes 0 for a summed bucket with no swap, but nothing before the first point", () => {
    const out = fillGaps([p(2, "5"), p(4, "7")], "sum", JAN1, JAN1 + 5 * 3_600, "hour");
    expect(out.map((x) => [x.t - JAN1, x.v])).toEqual([
      [7_200, "5"],
      [10_800, "0"],
      [14_400, "7"],
      [18_000, "0"],
    ]);
  });

  it("carries a sample from before the range into its first bucket", () => {
    const out = fillGaps([p(0, "10")], "first", JAN1 + 2 * 3_600, JAN1 + 3 * 3_600, "hour");
    expect(out.map((x) => x.v)).toEqual(["10", "10"]);
  });

  it("returns nothing for a scope listed after the range", () => {
    expect(fillGaps([p(10, "1")], "first", JAN1, JAN1 + 3_600, "hour")).toEqual([]);
  });
});
