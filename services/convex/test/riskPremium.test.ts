// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The risk premium of Borrow asset and Lend asset pages, from the chain.

import { describe, expect, it } from "vitest";
import type { MarketRow, SpokeReserveRow } from "@avana/services-common/views";
import { debtPremiumRange, debtRiskAssessment, lendPremiumYieldBps, lendRiskAssessment } from "../convex/lib/riskViews.ts";

const HUB = "0x00000000000000000000000000000000000000a1";
const OTHER_HUB = "0x00000000000000000000000000000000000000a2";
const reserve = (spoke: string, assetId: string, borrowable = true, hub = HUB) => ({ chainId: 1, spoke, hub, assetId, borrowable }) as unknown as SpokeReserveRow;
const market = (spoke: string, collateralRiskBps: number) => ({ chainId: 1, spoke, collateralRiskBps }) as unknown as MarketRow;

describe("Borrow asset premium", () => {
  const markets = [market("0xs1", 20), market("0xs1", 20), market("0xs2", 150), market("0xs3", 900), market("0xs4", 5_000)];

  it("spans every market whose Spoke lists the asset as borrowable on the same Hub", () => {
    const reserves = [reserve("0xs1", "3"), reserve("0xs2", "3"), reserve("0xs3", "3", false), reserve("0xs4", "3", true, OTHER_HUB), reserve("0xs4", "7")];
    expect(debtPremiumRange({ chainId: 1, hub: HUB, assetId: "3" }, reserves, markets)).toEqual({ min: 20, max: 150 });
    expect(debtPremiumRange({ chainId: 1, hub: HUB, assetId: "9" }, reserves, markets)).toBeNull();
  });

  it("shows one value when every market has the same premium, else the range", () => {
    const one = debtRiskAssessment({ min: 20, max: 20 }, "USDC");
    expect(one.premiumBps).toBe(20);
    expect(one).not.toHaveProperty("premiumMaxBps");
    const range = debtRiskAssessment({ min: 20, max: 150 }, "USDC");
    expect(range).toMatchObject({ premiumBps: 20, premiumMaxBps: 150 });
    expect(range.headline).toBe("0.20%–1.50% collateral risk premium");
  });
});

describe("Lend premium yield", () => {
  const RAY = 10n ** 27n;
  // 5 % drawn rate; 200 of premium debt on 1,000 added; 10 % liquidity fee → 0.05 × 0.2 × 0.9 = 0.9 % APR.
  const asset = { drawnRateRay: ((5n * RAY) / 100n).toString(), premium: "200", added: "1000", liquidityFeeBps: 1_000 };

  it("is the part of the supply rate paid by premium debt, as an APY", () => {
    // APY of a 0.9 % continuous rate: e^0.009 − 1 ≈ 0.904 % → 90 bps.
    expect(lendPremiumYieldBps(asset)).toBe(90);
    expect(lendPremiumYieldBps({ ...asset, added: "0" })).toBe(0);
    expect(lendRiskAssessment(asset, "USDC")).toMatchObject({ premiumBps: 90, headline: "0.90% premium yield" });
  });
});

describe("collateral premium wording", () => {
  it("says the premium is a share of the base rate, with the extra APR points at today's rate", async () => {
    const { collateralRiskDescription, poolRiskAssessment } = await import("../convex/lib/riskViews.ts");
    const RAY = 10n ** 27n;
    // Stable at 400 bps of a 5 % base rate: ×1.04, 0.20 extra points.
    expect(collateralRiskDescription(400, ((5n * RAY) / 100n).toString())).toBe(
      "Aave V4 collateral risk of the market's vault-token reserve: borrowers pay the base rate ×1.04, 0.20 extra APR points at today's 5.00% base rate.",
    );
    expect(collateralRiskDescription(400)).toBe("Aave V4 collateral risk of the market's vault-token reserve: borrowers pay the base rate ×1.04.");
    const card = poolRiskAssessment({ collateralRiskBps: 400, collateralFactorBps: 8_000, maxLiquidationBonusBps: 10_500, priceState: 0 } as never);
    expect(card).toMatchObject({ premiumBps: 400, premiumBasis: "baseRate", breakdown: [{ label: "Collateral risk (% of base rate)", bps: 400 }] });
  });
});
