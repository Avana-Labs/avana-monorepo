// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Decision and sizing rules of the liquidation job, on the boundaries where a wrong comparison would liquidate a
// healthy account, block a liquidatable one or let the funding Safe lose more than its bound.

import { describe, expect, it } from "vitest";
import {
  WAD,
  candidateReason,
  chooseDebtReserve,
  deadlineFor,
  marketGate,
  previewGate,
  requestMinPayout,
  routeMode,
  splitFunding,
  topUpBound,
} from "../src/jobs/liquidationRules.ts";

describe("candidateReason", () => {
  it("skips HF exactly 1 as healthy and acts just below it", () => {
    expect(candidateReason(WAD, 1n)).toBe("healthy");
    expect(candidateReason(WAD - 1n, 1n)).toBeNull();
  });

  it("skips an account with no collateral left", () => {
    expect(candidateReason(0n, 0n)).toBe("zeroCollateral");
  });
});

describe("marketGate", () => {
  const live = {
    liquidationState: 0,
    disagreementPauseActive: false,
    disagreementExpired: false,
    now: 1_000n,
    graceEndsAt: 0n,
    graceHealthFactor: (95n * WAD) / 100n,
    healthFactor: (99n * WAD) / 100n,
  };

  it("allows Live and Drifting, refuses Cached and Expired", () => {
    expect(marketGate(live)).toBeNull();
    expect(marketGate({ ...live, liquidationState: 1 })).toBeNull();
    expect(marketGate({ ...live, liquidationState: 2 })).toBe("marketNotLiquidatable");
    expect(marketGate({ ...live, liquidationState: 3 })).toBe("marketNotLiquidatable");
  });

  it("refuses during a disagreement pause", () => {
    expect(marketGate({ ...live, disagreementPauseActive: true })).toBe("disagreementPause");
    expect(marketGate({ ...live, disagreementExpired: true })).toBe("disagreementPause");
  });

  it("inside a grace window acts only below the grace health factor", () => {
    const grace = { ...live, graceEndsAt: 1_001n };
    expect(marketGate(grace)).toBe("graceAboveThreshold");
    expect(marketGate({ ...grace, healthFactor: grace.graceHealthFactor })).toBe("graceAboveThreshold");
    expect(marketGate({ ...grace, healthFactor: grace.graceHealthFactor - 1n })).toBeNull();
    // The window has ended at `graceEndsAt` itself.
    expect(marketGate({ ...grace, now: 1_001n })).toBeNull();
  });
});

describe("previewGate", () => {
  const ok = {
    aaveLiquidatable: true,
    pricesUsable: true,
    debtPriceFresh: true,
    inGrace: false,
    belowGraceHealthFactor: false,
    vaultTokenReservePaused: false,
    debtReservePaused: false,
    debtToCover: 1n,
  };

  it("passes when every field allows the call", () => {
    expect(previewGate(ok)).toBeNull();
  });

  it("names the first failing gate", () => {
    expect(previewGate({ ...ok, aaveLiquidatable: false })?.reason).toBe("healthy");
    expect(previewGate({ ...ok, debtPriceFresh: false })?.reason).toBe("priceTooOld");
    expect(previewGate({ ...ok, inGrace: true })?.reason).toBe("graceAboveThreshold");
    expect(previewGate({ ...ok, inGrace: true, belowGraceHealthFactor: true })).toBeNull();
    expect(previewGate({ ...ok, debtReservePaused: true })?.reason).toBe("previewGateFalse");
    expect(previewGate({ ...ok, debtToCover: 0n })?.detail).toBe("preview sized nothing");
  });
});

describe("chooseDebtReserve", () => {
  it("picks the largest reserve whose price passes; a failing price elsewhere does not block it", () => {
    expect(
      chooseDebtReserve([
        { debtReserveId: 1n, value: 900n, pricePasses: false },
        { debtReserveId: 2n, value: 500n, pricePasses: true },
        { debtReserveId: 3n, value: 400n, pricePasses: true },
      ]),
    ).toBe(2n);
  });

  it("returns null when no reserve has a passing price and a positive value", () => {
    expect(chooseDebtReserve([{ debtReserveId: 1n, value: 0n, pricePasses: true }])).toBeNull();
    expect(chooseDebtReserve([])).toBeNull();
  });
});

describe("call parameters", () => {
  it("sets the deadline three blocks after the decision block", () => {
    expect(deadlineFor(1_700_000_000n, 12)).toBe(1_700_000_036n);
    expect(deadlineFor(1_700_000_000n, 2)).toBe(1_700_000_006n);
  });

  it("uses BackupOnly only when every primary route is unusable", () => {
    expect(routeMode([{ routeKind: 0, usable: false }, { routeKind: 1, usable: true }])).toBe(1);
    expect(routeMode([{ routeKind: 0, usable: false }, { routeKind: 0, usable: true }])).toBe(0);
    expect(routeMode([{ routeKind: 1, usable: true }])).toBe(0);
  });
});

describe("splitFunding", () => {
  it("flash-borrows the whole debt when idle liquidity covers it with 1 % headroom", () => {
    expect(splitFunding(1_000n, 1_010n)).toEqual({ flashAmount: 1_000n, inventoryAmount: 0n });
  });

  it("otherwise borrows 99 % of idle liquidity and takes the rest from inventory", () => {
    expect(splitFunding(1_000n, 1_009n)).toEqual({ flashAmount: 998n, inventoryAmount: 2n });
    expect(splitFunding(1_000n, 500n)).toEqual({ flashAmount: 495n, inventoryAmount: 505n });
  });

  it("refuses a zero loan", () => {
    expect(splitFunding(1_000n, 1n)).toBeNull();
  });
});

describe("topUpBound", () => {
  const base = { premium: 5n, expectedCallerLoss: 20n, expectedNetPayout: 0n, expectedDebtRepaid: 2_000n, maxTopUpBps: 100n };

  it("is zero for a profitable call", () => {
    expect(topUpBound({ ...base, expectedNetPayout: 25n })).toBe(0n);
  });

  it("covers the expected loss up to MAX_TOP_UP_BPS of the debt repaid", () => {
    // premium 5 + loss 20 − payout 0 = 25 exceeds the cap, 1 % of 2,000 = 20.
    expect(topUpBound(base)).toBe(20n);
    expect(topUpBound({ ...base, expectedCallerLoss: 10n })).toBe(15n);
    expect(topUpBound({ ...base, expectedCallerLoss: 10n, expectedNetPayout: 3n })).toBe(12n);
  });
});

describe("requestMinPayout", () => {
  it("keeps 99 % of a simulated profit on top of the inventory put in", () => {
    expect(requestMinPayout(100n, 1_000n)).toBe(1_090n);
  });

  it("accepts at most 101 % of a simulated loss, rounded against the keeper", () => {
    expect(requestMinPayout(1_000n, -100n)).toBe(899n);
    expect(requestMinPayout(1_000n, -1n)).toBe(998n); // ceil(1.01) = 2
    expect(requestMinPayout(10n, -100n)).toBe(0n);
  });
});
