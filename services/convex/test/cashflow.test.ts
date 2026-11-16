// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The cashflow card: its rows total the last 90 days (the card scales 1D and 30D from them); its bars span every day.

import { describe, expect, it } from "vitest";
import { compactUsd } from "../convex/lib/format.ts";
import { CASHFLOW_ROW_DAYS, cashflow } from "../convex/lib/riskViews.ts";

// 1,000,000 USDC owed at $1 and a 3.65 % drawn rate: $100 of interest a day.
const day = { owed: (1_000_000n * 10n ** 6n).toString(10), drawnRateRay: (365n * 10n ** 23n).toString(10), priceUsd8: (10n ** 8n).toString(10) };
const start = Date.UTC(2025, 10, 16) / 1000;
const days = Array.from({ length: 365 }, (_, i) => ({ t: start + i * 86_400, hub: day }));

describe("cashflow", () => {
  it("totals the rows over the last 90 days, not the year", () => {
    const c = cashflow(days, 6, 1_000);
    const interest = 100 * CASHFLOW_ROW_DAYS;
    expect(c.rows.map((r) => r.reported)).toEqual([compactUsd(interest), compactUsd(interest * 0.9), compactUsd(interest * 0.1)]);
  });

  it("keeps a bar for every month of the year", () => {
    const c = cashflow(days, 6, 1_000);
    const total = c.bars[0]!.points.reduce((acc, p) => acc + p.v, 0);
    expect(total).toBeCloseTo(100 * 365, 6);
  });
});
