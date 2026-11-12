// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Token prices for the app's price layer: every Hub asset at its Lend Spoke oracle price, the price the pages value
// it at, and each market's vault token at its accepted LP price. No external price feed is used.

import { query } from "./_generated/server";
import { loadWorld, symbolOf } from "./model.ts";

/** Prices older than this are shown as stale; the sampler refreshes every 30 s. */
const STALE_AFTER_MS = 5 * 60_000;
const INVALID_AFTER_MS = 30 * 60_000;

export const getPriceSnapshot = query({
  args: {},
  handler: async (ctx) => {
    const w = await loadWorld(ctx);
    const now = Date.now();
    const status = (updatedAt: number) => (now - updatedAt > INVALID_AFTER_MS ? ("invalid" as const) : now - updatedAt > STALE_AFTER_MS ? ("stale" as const) : ("fresh" as const));
    const prices = [
      ...w.hubAssets.map((a) => ({ symbol: symbolOf(w, a.chainId, a.underlying).toLowerCase(), priceUsd: Number(BigInt(a.priceUsd8)) / 1e8, confidence: 1, source: "lendSpokeOracle" as const, status: status(a.updatedAt), updatedAt: a.updatedAt })),
      ...w.markets.map((m) => ({ symbol: m.symbol.toLowerCase(), priceUsd: Number(BigInt(m.acceptedPrice)) / 1e8, confidence: m.priceState === 0 ? 1 : 0.5, source: "lpOracle" as const, status: status(m.updatedAt), updatedAt: m.updatedAt })),
    ];
    const updatedAt = prices.length > 0 ? Math.min(...prices.map((p) => p.updatedAt)) : null;
    return { prices, status: { updatedAt, staleAfterMs: STALE_AFTER_MS, invalidAfterMs: INVALID_AFTER_MS, count: prices.length } };
  },
});

export const getPriceStatus = query({
  args: {},
  handler: async (ctx) => {
    const rows = await ctx.db.query("hubAssets").collect();
    return { updatedAt: rows.length > 0 ? Math.max(...rows.map((r) => r.updatedAt)) : null, staleAfterMs: STALE_AFTER_MS, count: rows.length };
  },
});
