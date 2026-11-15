// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// LP fee APR of a market's range and the 1D/30D/90D rate averages: fees per unit of active liquidity over the value
// of one unit across the range, 0 out of range; windows scale to a year; averages weight each day equally.

import { describe, expect, it } from "vitest";
import { feesPerLiquidityUsd, lpFeeAprPct, rateAverages, valuePerLiquidityUsd } from "../convex/lib/windows.ts";

const Q96 = (2n ** 96n).toString();
const stable = { decimals: [6, 6] as const, priceUsd: [1, 1] as const };
const at0 = { sqrtPriceX96: Q96, tickLower: -10, tickUpper: 10 };

describe("LP fee APR", () => {
  it("values one unit of liquidity across the range from both token amounts", () => {
    const s = Math.pow(1.0001, 5);
    const expected = ((1 - 1 / s) + (1 - 1 / s)) / 1e6;
    expect(valuePerLiquidityUsd(Q96, -10, 10, stable)).toBeCloseTo(expected, 15);
  });

  it("is zero out of range", () => {
    expect(valuePerLiquidityUsd(Q96, 10, 20, stable)).toBe(0);
    expect(lpFeeAprPct([{ fees0: "1000000000", liquidity: "1000000000000" }], 1, { ...at0, tickLower: 10, tickUpper: 20 }, stable)).toBe(0);
  });

  it("is fees per unit liquidity over the unit's value, annualised", () => {
    const day = [{ fees0: "600000000", fees1: "400000000", liquidity: "1000000000000" }];
    const perL = feesPerLiquidityUsd(day, stable);
    expect(perL).toBeCloseTo(1_000 / 1e12, 20);
    const apr = lpFeeAprPct(day, 1, at0, stable);
    expect(apr).toBeCloseTo((perL / valuePerLiquidityUsd(Q96, -10, 10, stable)) * 365 * 100, 6);
    // The same fees spread over 30 days give a thirtieth of the rate.
    expect(lpFeeAprPct(day, 30, at0, stable)).toBeCloseTo(apr / 30, 6);
  });

  it("skips buckets without active liquidity and counts both tokens", () => {
    expect(feesPerLiquidityUsd([{ fees0: "5", liquidity: "0" }, { fees1: "2000000", liquidity: "2" }], stable)).toBe(1);
  });
});

describe("rate averages", () => {
  it("averages each day equally and ignores days without rates", () => {
    const ray = (pct: number) => (BigInt(Math.round(pct * 1e4)) * 10n ** 21n).toString();
    const r = rateAverages([{ drawnRateRay: ray(4), supplyRateRay: ray(2), utilizationBps: "5000" }, { drawnRateRay: ray(6), supplyRateRay: ray(2), utilizationBps: "7000" }, {}]);
    expect(r?.borrowAprPct).toBeCloseTo(5, 6);
    expect(r?.utilizationPct).toBeCloseTo(60, 6);
    expect(rateAverages([])).toBeNull();
  });
});
