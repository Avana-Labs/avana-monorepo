// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Risk Parameters grid: each page type fills the slots that apply to its scope from chain values (the market's
// collateral factor, liquidation config and LPOracle, the RiskModule's band and LTV), and never fills a slot that does
// not apply.

import { describe, expect, it } from "vitest";
import { fixtureHubAsset, fixtureMarkets, fixtureSlices, fixtureSpokeReserves } from "@avana/services-common/fixtures";
import { RISK_SLOTS, assetRiskParameters, lendRiskParameters, liquidationPenaltyRange, poolRiskParameters } from "../convex/lib/riskViews.ts";

const slots = (p: { parameters: readonly { id: string; value: string }[] }) => Object.fromEntries(p.parameters.filter((r) => (RISK_SLOTS as readonly string[]).includes(r.id)).map((r) => [r.id, r.value]));

describe("risk parameter slots", () => {
  it("fills every slot but the deposit capacity on a pool page (the new core has no USD cap)", () => {
    const m = fixtureMarkets[0]!;
    const s = slots(poolRiskParameters("pool", m, "60000000000000000000000000", 250_000));
    expect(Object.keys(s).sort()).toEqual(RISK_SLOTS.filter((x) => x !== "depositCapacity").sort());
    expect(s.collateralFactor).toBe("90.00%");
    expect(s.liquidationThreshold).toBe("90.00%");
    expect(s.liquidationPenalty).toBe("2.50% – 5.00%");
    expect(s.borrowCapacity).toBe("$250.00K");
    expect(s.targetHealthFactor).toBe("1.10");
    expect(s.oracle).toMatch(/^Avana LP oracle 0x/);
  });

  it("names the market's range and LTV, and shows a depegged market frozen", () => {
    const [full, custom] = fixtureMarkets;
    const all = (m: typeof full) => Object.fromEntries(poolRiskParameters("pool", m!, null).parameters.map((r) => [r.id, r.value]));
    expect([all(full).range, all(custom).range]).toEqual(["Full range", "Custom range, ticks -100 to 100"]);
    expect(all(full).ltv).toBe("90.00%");
    expect(all({ ...full!, frozen: true }).reserve).toBe("Frozen");
    expect(slots(poolRiskParameters("pool", full!, null)).borrowCapacity).toBeUndefined();
  });

  it("fills only the slots a debt reserve and a Lend asset own", () => {
    const r = fixtureSpokeReserves[0]!;
    const slice = fixtureSlices.find((x) => x.spoke === r.spoke)!;
    const asset = slots(assetRiskParameters("a", r, slice, fixtureHubAsset, "USDC"));
    expect(Object.keys(asset).sort()).toEqual(["borrowCapacity", "oracle"]);
    const lend = slots(lendRiskParameters("l", fixtureHubAsset, fixtureSlices, "USDC"));
    expect(Object.keys(lend).sort()).toEqual(["borrowCapacity", "depositCapacity", "oracle"]);
  });

  it("shows the liquidation bonus as a range only when the factor scales it", () => {
    // Aave V4's maxLiquidationBonus is 10,000-based: 10,500 is a 5 % bonus.
    expect(liquidationPenaltyRange(10_500, 5_000)).toBe("2.50% – 5.00%");
    expect(liquidationPenaltyRange(10_500, 10_000)).toBe("5.00%");
    expect(liquidationPenaltyRange(10_500, null)).toBe("5.00%");
    expect(liquidationPenaltyRange(10_000, 5_000)).toBe("0.00%");
  });
});
