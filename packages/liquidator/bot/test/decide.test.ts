// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs

import { describe, expect, it } from "vitest";
import { ONE, decide, minProfit } from "../src/decide.ts";

const s = { healthFactor: ONE - 1n, debt: 1000n, balance: 0n, flash: true, flashBorrower: false };

describe("decide", () => {
  it("skips healthy accounts and empty debt", () => {
    expect(decide({ ...s, healthFactor: ONE })).toEqual({ kind: "skip", reason: "healthy" });
    expect(decide({ ...s, debt: 0n })).toEqual({ kind: "skip", reason: "no debt" });
  });

  it("prefers a premium-free flash loan", () => {
    expect(decide({ ...s, flashBorrower: true, balance: 5000n })).toEqual({ kind: "flash", flashAmount: 1000n });
  });

  it("uses its own funds before a flash loan with a premium", () => {
    expect(decide({ ...s, balance: 1000n })).toEqual({ kind: "direct", debtToCover: 1000n });
    expect(decide({ ...s, balance: 999n })).toEqual({ kind: "flash", flashAmount: 1000n });
  });

  it("without a flash path, covers what it can, and alerts when it has nothing", () => {
    expect(decide({ ...s, flash: false, balance: 400n })).toEqual({ kind: "direct", debtToCover: 400n });
    expect(decide({ ...s, flash: false })).toEqual({ kind: "unfunded", debt: 1000n });
  });

  it("keeps all but the slippage share of the simulated profit", () => {
    expect(minProfit(10_000n, 50n)).toBe(9950n);
    expect(minProfit(0n, 50n)).toBe(0n);
  });
});
