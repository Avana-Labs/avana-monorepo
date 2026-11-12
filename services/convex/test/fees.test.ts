// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The frontend fee and the total shown before signing: 10 bps on every app action by default, the 25 bps ceiling,
// the LP-value basis of pledge and withdraw collateral, rounding down, the USD cap, and gas of the simulated batch at
// the chain's gas price and native price.

import { describe, expect, it } from "vitest";
import { type AmountBasis, DEFAULT_FEE_RULES, FEE_ACTIONS, type FeeRules, feeBpsFor, LP_VALUE_ACTIONS, lpValueFee, MAX_FEE_BPS, quoteFee } from "../convex/lib/fees.ts";

// 200,000 gas at 20 gwei base + 1 gwei tip, ETH at $3,000.
const gas = { gasUnits: 200_000n, baseFeeWei: 20_000_000_000n, priorityFeeWei: 1_000_000_000n, l1FeeWei: 0n, nativeUsd8: 300_000_000_000n };
const usdc = (whole: number) => BigInt(whole) * 1_000_000n;
const ONE = 100_000_000n; // $1, 8 decimals
const amount = (units: bigint, priceUsd8 = ONE, decimals = 6): AmountBasis => ({ kind: "amount", amount: units, decimals, priceUsd8 });
const lpValue = (valueUsd8: bigint, priceUsd8 = ONE, decimals = 6) => ({ kind: "lpValue" as const, valueUsd8, decimals, priceUsd8 });

describe("frontend fee defaults", () => {
  it("charges 10 bps on every app action, with no exemptions and no USD cap", () => {
    expect(DEFAULT_FEE_RULES).toEqual({ enabled: true, defaultBps: 10, actionBps: {}, exemptActions: [], maxFeeUsd: null });
    expect(FEE_ACTIONS).toEqual(["supply", "withdraw", "pledge", "borrow", "repay", "withdrawCollateral", "repayWithCollateral", "deleverage", "swap"]);
    for (const action of FEE_ACTIONS) expect(feeBpsFor(DEFAULT_FEE_RULES, action)).toBe(10);
  });

  it("takes 10 USDC on each action worth $10,000", () => {
    for (const action of FEE_ACTIONS) {
      const basis = LP_VALUE_ACTIONS.has(action) ? lpValue(10_000n * ONE) : amount(usdc(10_000));
      const q = quoteFee(DEFAULT_FEE_RULES, { action, basis, gas });
      expect(q.feeBps, action).toBe(10);
      expect(q.feeAmount, action).toBe(usdc(10));
      expect(q.feeUsd, action).toBe(10);
      expect(q.capped, action).toBe(false);
    }
  });

  it("uses the LP-value basis for pledge and withdraw collateral only", () => {
    expect([...LP_VALUE_ACTIONS].sort()).toEqual(["pledge", "withdrawCollateral"]);
  });
});

describe("frontend fee ceiling", () => {
  it("is 25 bps", () => {
    expect(MAX_FEE_BPS).toBe(25);
  });

  it("accepts every integer rate up to the ceiling", () => {
    for (let bps = 0; bps <= MAX_FEE_BPS; bps++) expect(feeBpsFor({ ...DEFAULT_FEE_RULES, defaultBps: bps }, "borrow")).toBe(bps);
    expect(feeBpsFor({ ...DEFAULT_FEE_RULES, actionBps: { borrow: 25 } }, "borrow")).toBe(25);
  });

  it("throws on a default or per-action rate above the ceiling, whatever the action asked for", () => {
    expect(() => feeBpsFor({ ...DEFAULT_FEE_RULES, defaultBps: 26 }, "supply")).toThrow(/outside 0\.\.25/);
    expect(() => feeBpsFor({ ...DEFAULT_FEE_RULES, actionBps: { borrow: 26 } }, "supply")).toThrow(/borrow/);
    expect(() => quoteFee({ ...DEFAULT_FEE_RULES, defaultBps: 100 }, { action: "supply", basis: amount(usdc(1)), gas })).toThrow();
  });

  it("throws on a config above the ceiling even while fees are off or the action is exempt", () => {
    expect(() => feeBpsFor({ ...DEFAULT_FEE_RULES, enabled: false, defaultBps: 30 }, "supply")).toThrow();
    expect(() => feeBpsFor({ ...DEFAULT_FEE_RULES, exemptActions: ["supply"], defaultBps: 30 }, "supply")).toThrow();
  });

  it("throws on a negative or fractional rate", () => {
    expect(() => feeBpsFor({ ...DEFAULT_FEE_RULES, defaultBps: -1 }, "supply")).toThrow();
    expect(() => feeBpsFor({ ...DEFAULT_FEE_RULES, defaultBps: 10.5 }, "supply")).toThrow();
  });
});

describe("LP-value basis", () => {
  it("charges 10 bps of the position's oracle value in an 18-decimal stablecoin", () => {
    // A $200,000 position in a GHO market: 200 GHO.
    const q = quoteFee(DEFAULT_FEE_RULES, { action: "pledge", basis: lpValue(200_000n * ONE, ONE, 18), gas });
    expect(q.feeAmount).toBe(200n * 10n ** 18n);
    expect(q.amountUsd).toBe(200_000);
    expect(q.feeUsd).toBe(200);
    expect(q.direction).toBe("pay");
  });

  it("converts at the stablecoin's price and rounds down once", () => {
    // $10,000 at USDC $0.9999: ⌊10^12 × 10 × 10^6 / (10^4 × 99,990,000)⌋ = 10,001,000.
    expect(lpValueFee(10_000n * ONE, 10, 6, 99_990_000n)).toBe(10_001_000n);
    const q = quoteFee(DEFAULT_FEE_RULES, { action: "withdrawCollateral", basis: lpValue(10_000n * ONE, 99_990_000n), gas });
    expect(q.feeAmount).toBe(10_001_000n);
    expect(q.feeUsd).toBeLessThanOrEqual(10);
    expect(q.direction).toBe("receive");
  });

  it("refuses the wrong basis for an action", () => {
    expect(() => quoteFee(DEFAULT_FEE_RULES, { action: "pledge", basis: amount(usdc(1)), gas })).toThrow(/lpValue/);
    expect(() => quoteFee(DEFAULT_FEE_RULES, { action: "borrow", basis: lpValue(ONE), gas })).toThrow(/amount/);
  });

  it("refuses a zero stablecoin price and a negative value", () => {
    expect(() => lpValueFee(ONE, 10, 6, 0n)).toThrow();
    expect(() => quoteFee(DEFAULT_FEE_RULES, { action: "pledge", basis: lpValue(-1n), gas })).toThrow();
  });
});

describe("rounding", () => {
  it("rounds the amount fee down, never above the stated rate", () => {
    expect(quoteFee(DEFAULT_FEE_RULES, { action: "supply", basis: amount(999n), gas }).feeAmount).toBe(0n);
    expect(quoteFee(DEFAULT_FEE_RULES, { action: "repay", basis: amount(10_009n), gas }).feeAmount).toBe(10n);
    expect(quoteFee(DEFAULT_FEE_RULES, { action: "deleverage", basis: amount(usdc(1_234) + 567_890n), gas }).feeAmount).toBe(1_234_567n);
  });

  it("rounds the LP-value fee down", () => {
    // $0.99999999 at $1, 6 decimals: ⌊99,999,999 × 10 × 10^6 / 10^12⌋ = 999.
    expect(lpValueFee(99_999_999n, 10, 6, ONE)).toBe(999n);
    expect(lpValueFee(1n, 10, 6, ONE)).toBe(0n);
  });

  it("is the floor of amount × bps / 10⁴ at every rate up to the ceiling", () => {
    const amounts = [0n, 1n, 9_999n, 10_000n, 123_456_789n, 10n ** 30n + 7n];
    for (let bps = 0; bps <= MAX_FEE_BPS; bps++) {
      for (const a of amounts) {
        const fee = quoteFee({ ...DEFAULT_FEE_RULES, defaultBps: bps }, { action: "borrow", basis: amount(a), gas }).feeAmount;
        expect(fee * 10_000n <= a * BigInt(bps)).toBe(true);
        expect((fee + 1n) * 10_000n > a * BigInt(bps)).toBe(true);
      }
    }
  });

  it("is the floor of the LP value in stablecoin units at every rate up to the ceiling", () => {
    const values = [0n, 1n, 99_999_999n, 12_345n * ONE + 6_789n, 10n ** 20n];
    for (let bps = 0; bps <= MAX_FEE_BPS; bps++) {
      for (const v of values) {
        const fee = lpValueFee(v, bps, 6, 99_990_000n);
        const exact = v * BigInt(bps) * 10n ** 6n; // fee × 10⁴ × price ≤ exact < (fee + 1) × 10⁴ × price
        expect(fee * 10_000n * 99_990_000n <= exact).toBe(true);
        expect((fee + 1n) * 10_000n * 99_990_000n > exact).toBe(true);
      }
    }
  });
});

describe("totals and caps", () => {
  const rules: FeeRules = { enabled: true, defaultBps: 10, actionBps: { borrow: 25 }, exemptActions: ["repay"], maxFeeUsd: 500 };

  it("adds fee and gas to what a supply pays", () => {
    const q = quoteFee(rules, { action: "supply", basis: amount(usdc(10_000)), gas });
    expect(q.feeBps).toBe(10);
    expect(q.feeAmount).toBe(usdc(10));
    expect(q.feeUsd).toBe(10);
    expect(q.gasWei).toBe(4_200_000_000_000_000n);
    expect(q.gasUsd).toBeCloseTo(12.6, 10);
    expect(q.costUsd).toBeCloseTo(22.6, 10);
    expect(q.totalUsd).toBeCloseTo(10_022.6, 10);
    expect(q.direction).toBe("pay");
  });

  it("takes fee and gas from what a borrow receives, at a per-action rate within the ceiling", () => {
    const q = quoteFee(rules, { action: "borrow", basis: amount(usdc(10_000)), gas });
    expect(q.feeAmount).toBe(usdc(25));
    expect(q.totalUsd).toBeCloseTo(10_000 - 25 - 12.6, 10);
    expect(q.direction).toBe("receive");
  });

  it("charges nothing on an action an operator exempts or with fees off, and still shows gas", () => {
    const repay = quoteFee(rules, { action: "repay", basis: amount(usdc(10_000)), gas });
    expect(repay.feeAmount).toBe(0n);
    expect(repay.costUsd).toBeCloseTo(12.6, 10);
    expect(feeBpsFor({ ...rules, enabled: false }, "supply")).toBe(0);
  });

  it("caps the fee at the USD maximum, rounding the token amount down", () => {
    const q = quoteFee(rules, { action: "supply", basis: amount(usdc(10_000_000), 99_990_000n), gas });
    expect(q.capped).toBe(true);
    expect(q.feeAmount).toBe(500_050_005n); // ⌊500 × 10^6 × 10^8 / 99,990,000⌋
    expect(q.feeUsd).toBeLessThanOrEqual(500);
  });

  it("caps an LP-value fee in the stablecoin", () => {
    const q = quoteFee(rules, { action: "pledge", basis: lpValue(1_000_000n * ONE), gas });
    expect(q.capped).toBe(true);
    expect(q.feeAmount).toBe(usdc(500));
  });

  it("adds an L2's L1 data fee to the gas", () => {
    const base = { ...gas, baseFeeWei: 10_000_000n, priorityFeeWei: 1_000_000n, l1FeeWei: 50_000_000_000_000n };
    const q = quoteFee(rules, { action: "withdraw", basis: amount(usdc(1)), gas: base });
    expect(q.gasWei).toBe(200_000n * 11_000_000n + 50_000_000_000_000n);
    expect(q.gasUsd).toBeCloseTo(0.1566, 10);
  });

  it("refuses negative inputs", () => {
    expect(() => quoteFee(rules, { action: "supply", basis: amount(-1n, 1n), gas })).toThrow();
    expect(() => quoteFee(rules, { action: "supply", basis: amount(1n), gas: { ...gas, gasUnits: -1n } })).toThrow();
  });
});
