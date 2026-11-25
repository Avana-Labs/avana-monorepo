// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Live account summaries from Lens `getAccount`: Aave value units to USD, the no-debt health factor, WAD collateral
// factor to basis points, zero debts left out, gate flags kept by name.

import { describe, expect, it } from "vitest";
import { type AccountViewLike, accountSummary } from "../convex/lib/accounts.ts";

const view = (o: Partial<AccountViewLike> = {}): AccountViewLike => ({
  blockNumber: 21_400_000n,
  integrationId: 3,
  marketId: 7n,
  proxy: "0x00000000000000000000000000000000000000AA",
  deployed: true,
  healthFactor: 1_250_000_000_000_000_000n,
  totalCollateralValue: 20_000n * 10n ** 26n,
  totalDebtValueRay: 12_800n * 10n ** 26n * 10n ** 27n,
  avgCollateralFactor: 8n * 10n ** 17n,
  riskPremium: 500n,
  walletFrozen: false,
  breakerReasons: 0,
  debts: [
    { reserveId: 1n, asset: "0x00000000000000000000000000000000000000B1", total: 12_800n * 10n ** 18n, paused: false, priceFresh: true },
    { reserveId: 2n, asset: "0x00000000000000000000000000000000000000B2", total: 0n, paused: false, priceFresh: true },
  ],
  gateStatus: { borrowAllowed: true, withdrawWithDebtAllowed: false, reason: 3 },
  ...o,
});

describe("account summary", () => {
  it("converts Aave values and factors", () => {
    expect(accountSummary(view())).toEqual({
      integrationId: 3,
      marketId: "7",
      proxy: "0x00000000000000000000000000000000000000aa",
      deployed: true,
      healthFactor: 1.25,
      collateralUsd: 20_000,
      debtUsd: 12_800,
      avgCollateralFactorBps: 8_000,
      riskPremiumBps: 500,
      walletFrozen: false,
      breakerReasons: 0,
      debts: [{ reserveId: "1", asset: "0x00000000000000000000000000000000000000b1", total: (12_800n * 10n ** 18n).toString(), paused: false, priceFresh: true }],
      gates: { borrowAllowed: true, withdrawWithDebtAllowed: false },
      blockNumber: "21400000",
    });
  });

  it("reports no health factor without debt", () => {
    expect(accountSummary(view({ healthFactor: (1n << 256n) - 1n, totalDebtValueRay: 0n, debts: [] })).healthFactor).toBeNull();
  });
});
