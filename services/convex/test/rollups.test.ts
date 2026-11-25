// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Liquidation totals valued at each event's hour, and one day of Hub asset revenue split between the Hub and the
// suppliers.

import { describe, expect, it } from "vitest";
import { type LiquidationPricing, hourValue, liquidationTotals, previousUtcDay, revenueDay } from "../convex/lib/rollups.ts";

const H0 = 1_767_225_600_000; // 2026-01-01T00:00Z
const settled = (at: number, seized: string, debtRepaid: string) => ({ kind: "LiquidationModule.Liquidated", at, args: { debtReserveId: "1", seized, debtRepaid } });

describe("liquidation totals", () => {
  // The vault token is $2.00 in the first hour and $1.50 in the second; the debt asset stays $1.00.
  const hours = new Map([
    [H0 / 1000, { acceptedPrice: "200000000" }],
    [H0 / 1000 + 3_600, { acceptedPrice: "150000000" }],
  ]);
  const pricing: LiquidationPricing = {
    collateral: (at) => ({ priceUsd8: BigInt(hourValue(hours, at, "acceptedPrice") ?? "100000000"), decimals: 18 }),
    debt: () => ({ priceUsd8: 100_000_000n, decimals: 6 }),
    deficit: () => ({ priceUsd8: 100_000_000n, decimals: 6, drawnIndexRay: 11n * 10n ** 26n }),
  };

  it("values each liquidation at its hour's price and counts deficits as bad debt", () => {
    const logs = [
      settled(H0 + 60_000, (100n * 10n ** 18n).toString(), "150000000"),
      settled(H0 + 3_600_000 + 60_000, (100n * 10n ** 18n).toString(), "120000000"),
      { kind: "AaveSpoke.ReportDeficit", at: H0 + 7_000_000, args: { drawnShares: "10000000" }, spokeReserveKey: "1:0xs:1" },
      { kind: "AaveSpoke.Supply", at: H0, args: {} },
    ];
    expect(liquidationTotals(logs, H0, H0 + 86_400_000, pricing)).toEqual({ liquidations: 2, collateralSeizedUsd: 350, debtRepaidUsd: 270, badDebtUsd: 11 });
    expect(liquidationTotals(logs, H0, H0 + 3_600_000, pricing)).toMatchObject({ liquidations: 1, collateralSeizedUsd: 200 });
  });
});

describe("revenue", () => {
  it("splits one day of interest between the Hub and suppliers", () => {
    // 3,650,000 USDC owed at 10 % a year: 1,000 USDC of interest that day; a 10 % liquidity fee keeps 100.
    const day = { owed: (3_650_000n * 10n ** 6n).toString(), priceUsd8: "100000000", drawnRateRay: (10n ** 26n).toString() };
    const r = revenueDay(day, 6, 1_000);
    expect(r.interestUsd).toBeCloseTo(1_000, 6);
    expect(r.reserveUsd).toBeCloseTo(100, 6);
    expect(r.suppliersUsd).toBeCloseTo(900, 6);
  });

  it("rolls up the UTC day before now", () => {
    expect(previousUtcDay(H0 + 30 * 60_000)).toEqual({ day: "2025-12-31", from: H0 - 86_400_000, to: H0 });
  });
});
