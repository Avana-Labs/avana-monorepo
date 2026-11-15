// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The market risk score, model `avana-risk-v1`: 0 (safest) to 100, the sum of capped points from chain inputs the
// pages already read. The weights are this file's constants, so a risk-team model replaces this function and bumps
// RISK_MODEL; stored scores name the model that produced them.
//
// | Input | Points |
// |---|---|
// | Collateral risk premium (bps) | bps / 20, at most 30 |
// | USD cap usage above 50 % | 15 × (usage − 0.5) / 0.5 |
// | Price state | Live 0, Drifting 10, Cached 15, Expired 25 |
// | Market breaker tripped | 15 |
// | Hub pause | Frozen 10, Paused 20 |
// | Debt in accounts below health factor 1.10 | 20 × its share of the market's debt |
// | Bad debt reported in the last 7 days | 10 |
//
// Levels: below 20 low, below 40 moderate, below 60 elevated, else high.

import type { RiskLevel } from "./uiTypes.ts";

export const RISK_MODEL = "avana-risk-v1";

export interface RiskInputs {
  readonly collateralRiskBps: number;
  /** Used share of the market's USD cap, 0 to 1; null when the cap is not read. */
  readonly capUsage: number | null;
  readonly priceState: number;
  readonly breakerReasons: number;
  readonly pauseState: number;
  /** Share of the market's debt in accounts below health factor 1.10, 0 to 1. */
  readonly atRiskDebtShare: number;
  readonly badDebtUsd7d: number;
}

export interface RiskScore {
  readonly model: string;
  readonly score: number;
  readonly level: RiskLevel;
  readonly factors: readonly { readonly id: string; readonly label: string; readonly points: number; readonly value: string }[];
}

const PRICE_POINTS = [0, 10, 15, 25];
const PRICE_LABEL = ["Live", "Drifting", "Cached", "Expired"];
const round1 = (x: number) => Math.round(x * 10) / 10;

export const levelOf = (score: number): RiskLevel => (score < 20 ? "low" : score < 40 ? "moderate" : score < 60 ? "elevated" : "high");

export function scoreMarket(i: RiskInputs): RiskScore {
  const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
  const factors = [
    { id: "collateralRisk", label: "Collateral risk premium", points: Math.min(30, i.collateralRiskBps / 20), value: `${i.collateralRiskBps} bps` },
    { id: "capUsage", label: "Cap usage", points: i.capUsage === null ? 0 : (15 * Math.max(0, clamp01(i.capUsage) - 0.5)) / 0.5, value: i.capUsage === null ? "—" : `${round1(clamp01(i.capUsage) * 100)}%` },
    { id: "priceState", label: "Price state", points: PRICE_POINTS[i.priceState] ?? 25, value: PRICE_LABEL[i.priceState] ?? String(i.priceState) },
    { id: "breaker", label: "Market breaker", points: i.breakerReasons === 0 ? 0 : 15, value: i.breakerReasons === 0 ? "Clear" : "Tripped" },
    { id: "hubPause", label: "Hub pause", points: i.pauseState === 2 ? 20 : i.pauseState === 1 ? 10 : 0, value: ["None", "Frozen", "Paused"][i.pauseState] ?? String(i.pauseState) },
    { id: "atRiskDebt", label: "Debt below HF 1.10", points: 20 * clamp01(i.atRiskDebtShare), value: `${round1(clamp01(i.atRiskDebtShare) * 100)}%` },
    { id: "badDebt", label: "Bad debt (7d)", points: i.badDebtUsd7d > 0 ? 10 : 0, value: `$${Math.round(i.badDebtUsd7d).toLocaleString("en-US")}` },
  ].map((f) => ({ ...f, points: round1(f.points) }));
  const score = Math.min(100, Math.round(factors.reduce((acc, f) => acc + f.points, 0)));
  return { model: RISK_MODEL, score, level: levelOf(score), factors };
}

/** Debt share of accounts below `band` from their sampled collateral and debt values. */
export function atRiskDebtShare(positions: readonly { collateralUsd8: string; debtUsd8: string }[], collateralFactorBps: number, band = 1.1): number {
  let total = 0n;
  let risky = 0n;
  for (const p of positions) {
    const debt = BigInt(p.debtUsd8);
    if (debt === 0n) continue;
    total += debt;
    // HF = collateral × CF / debt < band  ⇔  collateral × CF × 100 < band × 100 × debt × 10⁴.
    if (BigInt(p.collateralUsd8) * BigInt(collateralFactorBps) * 100n < BigInt(Math.round(band * 100)) * debt * 10_000n) risky += debt;
  }
  return total === 0n ? 0 : Number((risky * 10_000n) / total) / 10_000;
}
