// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The gas limit covers the Hub accrual that `estimateGas` at `latest` misses: a call estimated in the second its Hub
// asset was already accrued is mined a second later and pays the accrual then.

import { describe, expect, it } from "vitest";
import { GAS_PAD_FIXED, paddedGasLimit } from "@avana/services-common/gas";
import { gasLimit } from "../src/chain/gas.ts";

describe("gas limit", () => {
  it("is ⌈1.3 × estimate⌉ + 25,000", () => {
    expect(gasLimit(0n)).toBe(25_000n);
    expect(gasLimit(10n)).toBe(25_013n);
    expect(gasLimit(11n)).toBe(25_015n); // 14.3 rounds up
    expect(gasLimit(1_000_000n)).toBe(1_325_000n);
    expect(gasLimit(5_150_000n)).toBe(6_720_000n); // the largest liquidation (REQ-SWAP-032)
  });

  it("covers the measured same-second gap of a Lend Spoke withdraw", () => {
    const sameSecond = 31_185n;
    const nextSecond = 35_837n;
    expect(gasLimit(sameSecond)).toBeGreaterThanOrEqual(nextSecond);
    // The previous rule, ⌈1.25 × estimate⌉ = 38,982, covered this call with 3,145 gas to spare; the fixed part keeps a
    // small call's margin well above one accrual even when the estimate is smaller still.
    expect(gasLimit(sameSecond) - nextSecond).toBeGreaterThan(GAS_PAD_FIXED);
  });

  it("never falls below the estimate and grows with it", () => {
    for (const e of [0n, 1n, 21_000n, 31_185n, 400_000n, 12_000_000n]) {
      expect(gasLimit(e)).toBeGreaterThan(e);
      expect(gasLimit(e + 1n)).toBeGreaterThanOrEqual(gasLimit(e));
    }
  });

  it("is the shared rule of every service", () => {
    expect(gasLimit(123_456n)).toBe(paddedGasLimit(123_456n));
    expect(() => paddedGasLimit(-1n)).toThrow(/non-negative/);
  });
});
