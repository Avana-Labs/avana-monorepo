// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Merkl matching per page ("rewards", a checked "none", or "unknown" when the check failed or is stale) and the
// market risk score's inputs, caps and levels.

import { describe, expect, it } from "vitest";
import { INCENTIVES_STALE_MS, type MerklOpportunity, incentiveStatus, matchIncentives } from "../convex/lib/incentives.ts";
import { RISK_MODEL, atRiskDebtShare, levelOf, scoreMarket } from "../convex/lib/riskScore.ts";

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}`;
const USDC = A(0xc0);
const opp = (o: Partial<MerklOpportunity>): MerklOpportunity => ({ chainId: 8453, status: "LIVE", apr: 4, tokens: [], ...o });

describe("Merkl incentives", () => {
  const targets = [
    { scope: "pool" as const, slug: "pool-a", addresses: [A(1), A(2)] },
    { scope: "lend" as const, slug: "lend-usdc", addresses: [A(9)], token: USDC },
  ];

  it("sums live campaigns naming a page's address, and checks the token for a Spoke page", () => {
    const opps = [
      opp({ identifier: A(1).toUpperCase().replace("0X", "0x"), apr: 3, rewardsRecord: { breakdowns: [{ token: { symbol: "AERO" } }] } }),
      opp({ explorerAddress: A(2), apr: 1.5 }),
      opp({ identifier: A(9), tokens: [{ address: USDC }], apr: 2 }),
      opp({ identifier: A(9), tokens: [{ address: A(0xd0) }], apr: 50 }),
      opp({ identifier: A(1), status: "PAST", apr: 99 }),
      opp({ identifier: A(1), chainId: 1, apr: 99 }),
    ];
    const [pool, lend] = matchIncentives(opps, 8453, targets);
    expect(pool).toEqual({ scope: "pool", slug: "pool-a", aprPct: 4.5, rewardTokens: ["AERO"], opportunities: 2 });
    expect(lend).toMatchObject({ aprPct: 2, opportunities: 1 });
  });

  it("says none only after a fresh successful check, else unknown", () => {
    const now = 1_000_000_000;
    const none = { aprPct: 0, rewardTokens: [], opportunities: 0 };
    expect(incentiveStatus(none, now - 1_000, now)).toEqual({ status: "none" });
    expect(incentiveStatus(null, now - 1_000, now)).toEqual({ status: "none" });
    expect(incentiveStatus(none, null, now)).toEqual({ status: "unknown" });
    expect(incentiveStatus(none, now - INCENTIVES_STALE_MS - 1, now)).toEqual({ status: "unknown" });
    expect(incentiveStatus({ aprPct: 3, rewardTokens: ["AERO"], opportunities: 1 }, now, now)).toEqual({ status: "rewards", aprPct: 3, rewardTokens: ["AERO"] });
  });
});

describe("market risk score", () => {
  const calm = { collateralRiskBps: 200, capUsage: 0.4, priceState: 0, breakerReasons: 0, pauseState: 0, atRiskDebtShare: 0, badDebtUsd7d: 0 };

  it("scores a calm market low and names its model", () => {
    const s = scoreMarket(calm);
    expect(s).toMatchObject({ model: RISK_MODEL, score: 10, level: "low" });
    expect(s.factors.map((f) => f.id)).toEqual(["collateralRisk", "capUsage", "priceState", "breaker", "hubPause", "atRiskDebt", "badDebt"]);
  });

  it("adds points for stress and caps the score at 100", () => {
    expect(scoreMarket({ ...calm, capUsage: 1, priceState: 3, atRiskDebtShare: 0.5 }).score).toBe(10 + 15 + 25 + 10);
    expect(scoreMarket({ collateralRiskBps: 5_000, capUsage: 1, priceState: 3, breakerReasons: 1, pauseState: 2, atRiskDebtShare: 1, badDebtUsd7d: 1 }).score).toBe(100);
    expect(scoreMarket({ ...calm, capUsage: null }).factors.find((f) => f.id === "capUsage")?.value).toBe("—");
  });

  it("maps scores to levels and measures debt below the band", () => {
    expect([0, 19, 20, 39, 40, 59, 60].map(levelOf)).toEqual(["low", "low", "moderate", "moderate", "elevated", "elevated", "high"]);
    // HF 0.8 × 1,000 / 1,000 = 0.80 (at risk, debt 1,000) and 0.8 × 3,000 / 1,000 = 2.40 (safe, debt 1,000).
    const p = [
      { collateralUsd8: "100000000000", debtUsd8: "100000000000" },
      { collateralUsd8: "300000000000", debtUsd8: "100000000000" },
      { collateralUsd8: "100000000", debtUsd8: "0" },
    ];
    expect(atRiskDebtShare(p, 8_000)).toBe(0.5);
  });
});
