// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The hourly market risk score job (lib/riskScore.ts): one row per market with the score, its level, the points of
// each input and the model that produced it. The pool page's risk card reads it (details.readRiskScored).

import { internalMutation } from "./_generated/server";
import { atRiskDebtShare, scoreMarket } from "./lib/riskScore.ts";
import { loadWorld } from "./model.ts";

export const score = internalMutation({
  args: {},
  handler: async (ctx) => {
    const w = await loadWorld(ctx);
    const now = Date.now();
    const since = new Date(now - 7 * 86_400_000).toISOString().slice(0, 10);
    for (const m of w.markets) {
      const positions = await ctx.db.query("positions").withIndex("by_market", (q) => q.eq("chainId", m.chainId).eq("marketId", m.marketId)).collect();
      const rollups = await ctx.db
        .query("dailyRollups")
        .withIndex("by_scope", (q) => q.eq("scopeKind", "market").eq("scopeKey", `${m.chainId}:${m.marketId}`).gte("day", since))
        .collect();
      const result = scoreMarket({
        collateralRiskBps: m.collateralRiskBps,
        // No USD cap or breaker in the new core; an unpriced market scores as an expired price, a frozen or paused
        // reserve as the old Hub pause did.
        capUsage: null,
        priceState: m.priceAvailable ? 0 : 3,
        breakerReasons: 0,
        pauseState: m.paused ? 2 : m.frozen ? 1 : 0,
        atRiskDebtShare: atRiskDebtShare(positions, m.collateralFactorBps),
        badDebtUsd7d: rollups.reduce((acc, r) => acc + (r.values.badDebtUsd ?? 0), 0),
      });
      const row = { chainId: m.chainId, marketId: m.marketId, ...result, factors: [...result.factors], computedAt: now };
      const existing = await ctx.db.query("riskScores").withIndex("by_market", (q) => q.eq("chainId", m.chainId).eq("marketId", m.marketId)).unique();
      if (existing) await ctx.db.replace(existing._id, row);
      else await ctx.db.insert("riskScores", row);
    }
    return { markets: w.markets.length };
  },
});
