// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Merkl incentives per page. A page is a target: an address the campaign names (Merkl's `identifier` or
// `explorerAddress`) and, for a Lend or Borrow asset page, the token the campaign must pay on, since one Spoke holds
// many reserves. A pool page targets the market's pool and its vault token. A target matched by no live opportunity
// after a successful fetch has no rewards ("none"); a failed or stale fetch leaves it "unknown", so the app never
// shows "No rewards" it has not checked.

export interface MerklOpportunity {
  readonly chainId: number;
  readonly identifier?: string;
  readonly explorerAddress?: string;
  readonly status?: string;
  readonly apr?: number;
  readonly tokens?: readonly { readonly address?: string; readonly symbol?: string }[];
  readonly rewardsRecord?: { readonly breakdowns?: readonly { readonly token?: { readonly symbol?: string } }[] };
}

export interface IncentiveTarget {
  readonly scope: "lend" | "asset" | "pool";
  readonly slug: string;
  /** Lower-case addresses a campaign may name for this page. */
  readonly addresses: readonly string[];
  /** For Lend and Borrow asset pages: the campaign must list this token (lower case). */
  readonly token?: string;
}

export interface IncentiveMatch {
  readonly scope: IncentiveTarget["scope"];
  readonly slug: string;
  readonly aprPct: number;
  readonly rewardTokens: readonly string[];
  readonly opportunities: number;
}

/** After this long without a successful fetch, a page's incentives are unknown again. */
export const INCENTIVES_STALE_MS = 3 * 60 * 60 * 1000;

const lower = (a: string | undefined) => (a ?? "").toLowerCase();

export function matchIncentives(opps: readonly MerklOpportunity[], chainId: number, targets: readonly IncentiveTarget[]): IncentiveMatch[] {
  const out: IncentiveMatch[] = [];
  for (const t of targets) {
    let aprPct = 0;
    let n = 0;
    const tokens = new Set<string>();
    for (const o of opps) {
      if (o.chainId !== chainId || (o.status !== undefined && o.status !== "LIVE")) continue;
      if (!t.addresses.includes(lower(o.identifier)) && !t.addresses.includes(lower(o.explorerAddress))) continue;
      if (t.token && !(o.tokens ?? []).some((x) => lower(x.address) === t.token)) continue;
      const apr = typeof o.apr === "number" && Number.isFinite(o.apr) && o.apr > 0 ? o.apr : 0;
      aprPct += apr;
      n += 1;
      for (const b of o.rewardsRecord?.breakdowns ?? []) if (b.token?.symbol) tokens.add(b.token.symbol);
    }
    out.push({ scope: t.scope, slug: t.slug, aprPct, rewardTokens: [...tokens].sort(), opportunities: n });
  }
  return out;
}

export type IncentiveStatus = { readonly status: "rewards"; readonly aprPct: number; readonly rewardTokens: readonly string[] } | { readonly status: "none" } | { readonly status: "unknown" };

/** What a page shows, from its stored match and the chain's last successful fetch time. */
export function incentiveStatus(match: { aprPct: number; rewardTokens: readonly string[]; opportunities: number } | null, lastOkAt: number | null, now: number): IncentiveStatus {
  if (lastOkAt === null || now - lastOkAt > INCENTIVES_STALE_MS) return { status: "unknown" };
  if (!match || match.opportunities === 0) return { status: "none" };
  return { status: "rewards", aprPct: match.aprPct, rewardTokens: match.rewardTokens };
}
