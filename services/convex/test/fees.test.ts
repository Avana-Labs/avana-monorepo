// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The frontend fee and the total shown before signing: rate per action, exemptions, the USD cap, rounding, and gas
// of the simulated batch at the chain's gas price and native price.

import { describe, expect, it } from "vitest";
import { DEFAULT_FEE_RULES, type FeeRules, feeBpsFor, quoteFee } from "../convex/lib/fees.ts";

const rules: FeeRules = { enabled: true, defaultBps: 10, actionBps: { borrow: 25 }, exemptActions: ["repay"], maxFeeUsd: 500 };
// 200,000 gas at 20 gwei base + 1 gwei tip, ETH at $3,000.
const gas = { gasUnits: 200_000n, baseFeeWei: 20_000_000_000n, priorityFeeWei: 1_000_000_000n, l1FeeWei: 0n, nativeUsd8: 300_000_000_000n };
const usdc = (whole: number) => BigInt(whole) * 1_000_000n;

describe("frontend fee", () => {
  it("adds fee and gas to what a supply pays", () => {
    const q = quoteFee(rules, { action: "supply", amount: usdc(10_000), decimals: 6, priceUsd8: 100_000_000n, gas });
    expect(q.feeBps).toBe(10);
    expect(q.feeAmount).toBe(usdc(10));
    expect(q.feeUsd).toBe(10);
    expect(q.gasWei).toBe(4_200_000_000_000_000n);
    expect(q.gasUsd).toBeCloseTo(12.6, 10);
    expect(q.costUsd).toBeCloseTo(22.6, 10);
    expect(q.totalUsd).toBeCloseTo(10_022.6, 10);
    expect(q.direction).toBe("pay");
  });

  it("takes fee and gas from what a borrow receives, at the borrow rate", () => {
    const q = quoteFee(rules, { action: "borrow", amount: usdc(10_000), decimals: 6, priceUsd8: 100_000_000n, gas });
    expect(q.feeAmount).toBe(usdc(25));
    expect(q.totalUsd).toBeCloseTo(10_000 - 25 - 12.6, 10);
    expect(q.direction).toBe("receive");
  });

  it("charges nothing on an exempt action or with fees off, and still shows gas", () => {
    const repay = quoteFee(rules, { action: "repay", amount: usdc(10_000), decimals: 6, priceUsd8: 100_000_000n, gas });
    expect(repay.feeAmount).toBe(0n);
    expect(repay.costUsd).toBeCloseTo(12.6, 10);
    expect(feeBpsFor(DEFAULT_FEE_RULES, "supply")).toBe(0);
  });

  it("caps the fee at the USD maximum, rounding the token amount down", () => {
    const q = quoteFee(rules, { action: "supply", amount: usdc(10_000_000), decimals: 6, priceUsd8: 99_990_000n, gas });
    expect(q.capped).toBe(true);
    expect(q.feeAmount).toBe(500_050_005n); // ⌊500 × 10^6 × 10^8 / 99,990,000⌋
    expect(q.feeUsd).toBeLessThanOrEqual(500);
  });

  it("rounds the fee down, never above the stated rate", () => {
    const q = quoteFee(rules, { action: "supply", amount: 999n, decimals: 6, priceUsd8: 100_000_000n, gas });
    expect(q.feeAmount).toBe(0n);
  });

  it("adds an L2's L1 data fee to the gas", () => {
    const base = { ...gas, baseFeeWei: 10_000_000n, priorityFeeWei: 1_000_000n, l1FeeWei: 50_000_000_000_000n };
    const q = quoteFee(rules, { action: "withdraw", amount: usdc(1), decimals: 6, priceUsd8: 100_000_000n, gas: base });
    expect(q.gasWei).toBe(200_000n * 11_000_000n + 50_000_000_000_000n);
    expect(q.gasUsd).toBeCloseTo(0.1566, 10);
  });

  it("refuses a rate outside 0..10,000 bps and negative inputs", () => {
    expect(() => feeBpsFor({ ...rules, defaultBps: 10_001 }, "supply")).toThrow();
    expect(() => quoteFee(rules, { action: "supply", amount: -1n, decimals: 6, priceUsd8: 1n, gas })).toThrow();
  });
});
