// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Swap routes for the rehearsal's config generators: two Uniswap v3 paths of at most three pools (DexHops.MAX_HOPS) from
// a token into an asset that share no pool and no intermediate token but the asset and avoid the market's own pool, as
// the MarketRegistry requires (REQ-ROUTE-003), found by search over the test world's pools.

type Json = Record<string, any>;
export type Route = { token: string; asset: string; primary: string[]; backup: string[] };
const MAX_HOPS = 3;

/** Every simple path of pools from `from` to `to`, at most MAX_HOPS long, avoiding `banned`: shortest first, then the
 *  deepest (the largest smallest pool, by the world's `usd`), so a liquidation swap avoids a thin pool when it can. */
function paths(pools: readonly Json[], from: string, to: string, banned: ReadonlySet<string>): string[][] {
  const out: string[][] = [];
  const walk = (at: string, used: string[], seen: Set<string>) => {
    if (at === to && used.length > 0) return void out.push([...used]);
    if (used.length === MAX_HOPS) return;
    for (const p of pools) {
      if (banned.has(p.name) || used.includes(p.name) || (p.a !== at && p.b !== at)) continue;
      const next = p.a === at ? p.b : p.a;
      if (seen.has(next)) continue;
      seen.add(next);
      walk(next, [...used, p.name], seen);
      seen.delete(next);
    }
  };
  walk(from, [], new Set([from]));
  const depth = (path: readonly string[]) => Math.min(...path.map((n) => Number(pools.find((p) => p.name === n)!.usd ?? 0)));
  return out.sort((x, y) => x.length - y.length || depth(y) - depth(x));
}

/** The tokens a path of pools holds between hops (every token it reaches but the last). */
function intermediates(pools: readonly Json[], from: string, path: readonly string[]): string[] {
  const out: string[] = [];
  let at = from;
  for (const name of path.slice(0, -1)) {
    const p = pools.find((x) => x.name === name)!;
    at = p.a === at ? p.b : p.a;
    out.push(at);
  }
  return out;
}

/** A primary and a backup route from `token` into `asset` for the market on `ownPool` that share no pool and no
 *  intermediate token other than `asset` (REQ-ROUTE-003); throws when there is none. */
export function routePair(config: Json, market: string, token: string, asset: string, ownPool: string): Route {
  const pools = config.world.uniswapPools as Json[];
  const all = paths(pools, token, asset, new Set([ownPool]));
  for (const p of all) {
    const via = intermediates(pools, token, p).filter((t) => t !== asset);
    const b = all.find((q) => q.every((x) => !p.includes(x)) && !intermediates(pools, token, q).some((t) => via.includes(t)));
    if (b) return { token, asset, primary: p, backup: b };
  }
  throw new Error(`${market}: no two routes from ${token} into ${asset} sharing no pool and no intermediate (found ${all.length} paths)`);
}

/** The world pool (Uniswap v3 or Slipstream) named `name`. */
export function poolOf(config: Json, name: string): Json | undefined {
  return (config.world.uniswapPools as Json[]).find((p) => p.name === name) ?? (config.world.slipstreamPools as Json[]).find((p) => p.name === name);
}

/** Adds each pool a route names to `listing.pools`. */
export function addRoutePools(config: Json, routes: readonly Route[]) {
  for (const r of routes)
    for (const name of [...r.primary, ...r.backup])
      config.listing.pools[name] ??= (config.world.uniswapPools as Json[]).some((p) => p.name === name)
        ? `$world:.uniswapPools['${name}']`
        : `$world:.slipstreamPools['${name}']`;
}
