// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Token prices for the app's price layer: every Hub asset at its Lend Spoke oracle price, the price the pages value
// it at, and each market's vault token at its accepted LP price. A token the protocol does not price (a wallet token
// no Hub lists) takes its DefiLlama price (`tokenPrices`, by symbol, from the token's mainnet counterpart), for display
// only.

import { query } from "./_generated/server";
import { loadWorld, priceAsset, symbolOf } from "./model.ts";
import { classifyPriceStatus } from "./tokenPrices.ts";

/** Prices older than this are shown as stale; the sampler refreshes every 30 s. */
const STALE_AFTER_MS = 5 * 60_000;
const INVALID_AFTER_MS = 30 * 60_000;

/** Symbols that name the same price: the app names native ETH "eth" and the Hubs list WETH. */
const SAME_PRICE: Readonly<Record<string, string>> = { eth: "weth", weth: "eth" };

/**
 * The protocol's rows, then an external row for each symbol the protocol does not price, then the `SAME_PRICE` alias of
 * a priced symbol that has no row of its own (from the protocol's row first). Symbols are lowercase.
 */
export function mergePriceRows<P extends { symbol: string }, E extends { symbol: string }>(protocol: readonly P[], external: readonly E[]): (P | E)[] {
  const out: (P | E)[] = [...protocol];
  const priced = new Set(protocol.map((p) => p.symbol));
  for (const row of external) {
    if (priced.has(row.symbol)) continue;
    priced.add(row.symbol);
    out.push(row);
  }
  for (const [symbol, alias] of Object.entries(SAME_PRICE)) {
    if (priced.has(symbol)) continue;
    const source = out.find((r) => r.symbol === alias);
    if (source) out.push({ ...source, symbol });
  }
  return out;
}

export const getPriceSnapshot = query({
  args: {},
  handler: async (ctx) => {
    const w = await loadWorld(ctx);
    const now = Date.now();
    const status = (updatedAt: number) => (now - updatedAt > INVALID_AFTER_MS ? ("invalid" as const) : now - updatedAt > STALE_AFTER_MS ? ("stale" as const) : ("fresh" as const));
    const protocol = [
      // One price per token and chain: a token on several Hubs is priced on the Hub `priceAsset` picks.
      ...w.hubAssets.filter((a) => priceAsset(w, a.chainId, a.underlying) === a).map((a) => ({ symbol: symbolOf(w, a.chainId, a.underlying).toLowerCase(), priceUsd: Number(BigInt(a.priceUsd8)) / 1e8, confidence: 1, source: "lendSpokeOracle" as const, status: status(a.updatedAt), updatedAt: a.updatedAt })),
      ...w.markets.map((m) => ({ symbol: m.symbol.toLowerCase(), priceUsd: Number(BigInt(m.acceptedPrice)) / 1e8, confidence: m.priceState === 0 ? 1 : 0.5, source: "lpOracle" as const, status: status(m.updatedAt), updatedAt: m.updatedAt })),
    ];
    // An unchanged quote is not rewritten (`upsertPrices`), so a row is as recent as the provider's last check. A coin
    // missing from that check's response keeps the check's time too; these prices are for display only.
    const checkedAt = (await ctx.db.query("oracleProviderHealth").withIndex("by_kind", (q) => q.eq("kind", "prices")).unique())?.checkedAt ?? 0;
    const external = (await ctx.db.query("tokenPrices").collect()).map((r) => {
      const updatedAt = Math.max(r.updatedAt, checkedAt);
      return { symbol: r.symbol, priceUsd: r.priceUsd, confidence: r.confidence ?? 1, source: "defillama" as const, status: classifyPriceStatus(now - updatedAt), updatedAt };
    });
    const prices = mergePriceRows(protocol, external);
    // Freshness is the protocol's: the external rows refresh on their own 10-minute cron and carry their own status.
    const updatedAt = protocol.length > 0 ? Math.min(...protocol.map((p) => p.updatedAt)) : null;
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
