// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Risk Parameters grid: each page type fills the slots that apply to its scope from chain values (the market's
// caps, threshold and oracle from `Lens.getMarket`), and never fills a slot that does not apply.

import { describe, expect, it } from "vitest";
import { fixtureHubAsset, fixtureMarkets, fixtureSlices, fixtureSpokeReserves } from "@avana/services-common/fixtures";
import { RISK_SLOTS, assetRiskParameters, lendRiskParameters, liquidationPenaltyRange, poolRiskParameters } from "../convex/lib/riskViews.ts";

const slots = (p: { parameters: readonly { id: string; value: string }[] }) => Object.fromEntries(p.parameters.filter((r) => (RISK_SLOTS as readonly string[]).includes(r.id)).map((r) => [r.id, r.value]));

describe("risk parameter slots", () => {
  it("fills all eight slots on a pool page from the market view", () => {
    const m = fixtureMarkets[0]!;
    const s = slots(poolRiskParameters("pool", m, "60000000000000000000000000", 250_000));
    expect(Object.keys(s).sort()).toEqual([...RISK_SLOTS].sort());
    expect(s.collateralFactor).toBe("80.00%");
    expect(s.liquidationThreshold).toBe("80.00%");
    expect(s.depositCapacity).toBe("$1.00M / $2.00M");
    expect(s.liquidationPenalty).toBe("2.50% – 5.00%");
    expect(s.borrowCapacity).toBe("$250.00K");
    expect(s.targetHealthFactor).toBe("1.10");
    expect(s.oracle).toMatch(/^Avana LP oracle 0x/);
  });

  it("leaves capacity and threshold slots out for a market row stored before the caps were read", () => {
    const { caps: _drop, ...old } = fixtureMarkets[0]!;
    const s = slots(poolRiskParameters("pool", old as never, null));
    expect(s.depositCapacity).toBeUndefined();
    expect(s.liquidationThreshold).toBeUndefined();
    expect(s.borrowCapacity).toBeUndefined();
    expect(s.collateralFactor).toBe("80.00%");
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
