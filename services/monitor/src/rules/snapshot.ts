// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The signals judged from one chain snapshot (`@avana/services-common/views`), every row read at one block:
// M-01 (market price state), M-06 (collateral value fall), M-08 (breakers), M-15 (Hub deficit), M-18 (draw cap use),
// M-19 (utilization, Lend Spoke withdrawals), M-24 (pause and manual-breaker changes) and M-29 (rate-curve changes).
// The rules are pure apart from `SnapshotMemory`, which carries the previous snapshot, the one-hour history and how
// long each deficit has been uncovered.

import { MAX_SPOKE_CAP } from "@avana/services-common/views";
import type { ChainSnapshot, HubAssetRow, MarketRow, SpokeReserveRow } from "@avana/services-common/views";
import { History } from "../history.ts";
import { type Level, ratioLevel } from "../signals.ts";
import type { Finding } from "../types.ts";

/** `PriceState` of the contracts: Live, Drifting, Cached, Expired. */
export const PRICE_STATE = ["Live", "Drifting", "Cached", "Expired"] as const;
/** `PauseState` of the contracts: None, Frozen, Paused. */
export const PAUSE_STATE = ["None", "Frozen", "Paused"] as const;

/** `BreakerReasons` bits (contracts/src/policy/market-registry/types/Breaker.sol). */
export const BREAKER = { ORACLE: 1 << 0, POOL_SHARE: 1 << 2, ISSUER: 1 << 3, DEFICIT: 1 << 5, MANUAL: 1 << 9, CONFIG_DRIFT: 1 << 10, POOL_DEPTH: 1 << 11 } as const;
/** The security freezes: they latch until an authorized reset (Q-399), so any of them pages M-08. */
export const SECURITY_FREEZE = BREAKER.ISSUER | BREAKER.DEFICIT | BREAKER.MANUAL | BREAKER.CONFIG_DRIFT;

export function breakerNames(reasons: number): string {
  const names = Object.entries(BREAKER).filter(([, bit]) => (reasons & bit) !== 0).map(([n]) => n);
  return names.length > 0 ? names.join("|") : "none";
}

const HOUR = 3_600;
const DAY = 86_400;

export class SnapshotMemory {
  readonly history = new History(HOUR);
  previous: ChainSnapshot | null = null;
  /** Unix seconds since which each Hub asset's deficit has been uncovered by both loss layers. */
  readonly uncoveredSince = new Map<string, number>();
}

export const marketKey = (m: Pick<MarketRow, "marketId">) => `market:${m.marketId}`;
export const reserveKey = (r: Pick<SpokeReserveRow, "spoke" | "reserveId">) => `reserve:${r.spoke}:${r.reserveId}`;
export const hubAssetKey = (a: Pick<HubAssetRow, "hub" | "assetId">) => `hubAsset:${a.hub}:${a.assetId}`;
export const sliceKey = (hub: string, assetId: string, spoke: string) => `slice:${hub}:${assetId}:${spoke}`;

const condition = (signal: Finding["signal"], level: Level, subject: string, detail: Record<string, string>): Finding => ({ signal, kind: "condition", level, subject, detail });
const event = (signal: Finding["signal"], subject: string, detail: Record<string, string>): Finding => ({ signal, kind: "event", level: "warn", subject, detail });

/** M-01 for a market's LPOracle: Cached warns, Expired pages. */
export function m01(m: MarketRow): Finding {
  const level: Level = m.priceState === 3 ? "page" : m.priceState === 2 ? "warn" : "ok";
  return condition("M-01", level, marketKey(m), { market: m.name, priceState: PRICE_STATE[m.priceState] ?? String(m.priceState) });
}

/** M-08: any breaker reason warns; a security freeze (issuer, deficit, manual, configuration drift) pages. */
export function m08(subject: string, reasons: number, label: string): Finding {
  const level: Level = (reasons & SECURITY_FREEZE) !== 0 ? "page" : reasons !== 0 ? "warn" : "ok";
  return condition("M-08", level, subject, { scope: label, reasons: breakerNames(reasons) });
}

/** M-18: a CDP Spoke's owed amount against its draw cap (whole tokens); none for an unlimited or zero cap. */
export function m18(owed: bigint, drawCapWhole: bigint, decimals: number): Level | null {
  if (drawCapWhole === 0n || drawCapWhole === MAX_SPOKE_CAP) return null;
  return ratioLevel(owed, drawCapWhole * 10n ** BigInt(decimals), [80n, 100n], [90n, 100n], "atOrAbove");
}

/** M-19: utilization 90 % warns and 98 % pages. */
export function m19Utilization(utilizationBps: number): Level {
  return utilizationBps >= 9_800 ? "page" : utilizationBps >= 9_000 ? "warn" : "ok";
}

/** A fall over the window, in bps of the window's peak, against warn and page limits. */
export function dropLevel(dropBps: bigint, warnBps: bigint, pageBps: bigint | null): Level {
  if (pageBps !== null && dropBps >= pageBps) return "page";
  return dropBps >= warnBps ? "warn" : "ok";
}

const rateCurveText = (a: HubAssetRow) => JSON.stringify(a.rateCurve);

/** Every finding of one snapshot, updating `mem`. Run once per snapshot, in block order. */
export function evaluateSnapshot(snap: ChainSnapshot, mem: SnapshotMemory): Finding[] {
  const out: Finding[] = [];
  const t = snap.timestamp;
  const seen = new Set<string>();
  const prev = mem.previous;
  const decimalsOf = new Map(snap.hubAssets.map((a) => [hubAssetKey(a), a.decimals]));

  for (const m of snap.markets) {
    const key = marketKey(m);
    out.push(m01(m));
    out.push(m08(key, m.breakerReasons, `market ${m.name}`));
    // M-06: collateral value at oracle prices, −10 % in 1 hour warns, −25 % pages.
    const valueKey = `${key}:suppliedUsd8`;
    seen.add(valueKey);
    mem.history.record(valueKey, t, BigInt(m.suppliedUsd8));
    const drop = mem.history.dropBps(valueKey);
    out.push(condition("M-06", dropLevel(drop, 1_000n, 2_500n), key, { market: m.name, valueUsd8: m.suppliedUsd8, dropBps: drop.toString(10) }));
  }

  for (const r of snap.spokeReserves) {
    out.push(m08(reserveKey(r), r.breakerReasons, `debt reserve ${r.reserveId} of ${r.spoke}`));
  }

  for (const a of snap.hubAssets) {
    const key = hubAssetKey(a);
    out.push(condition("M-19", m19Utilization(a.utilizationBps), key, { utilizationBps: String(a.utilizationBps) }));
    // M-15: any deficit warns; one uncovered by both loss layers for 24 hours pages.
    const deficit = BigInt(a.deficit);
    const uncovered = a.exposure ? BigInt(a.exposure.uncovered) : 0n;
    if (uncovered > 0n) {
      if (!mem.uncoveredSince.has(key)) mem.uncoveredSince.set(key, t);
    } else mem.uncoveredSince.delete(key);
    const since = mem.uncoveredSince.get(key);
    const level: Level = since !== undefined && t - since >= DAY ? "page" : deficit > 0n || uncovered > 0n ? "warn" : "ok";
    out.push(condition("M-15", level, key, { deficit: a.deficit, uncovered: uncovered.toString(10), ...(since !== undefined ? { uncoveredSince: String(since) } : {}) }));
  }

  for (const s of snap.slices) {
    const key = sliceKey(s.hub, s.assetId, s.spoke);
    const decimals = decimalsOf.get(`hubAsset:${s.hub}:${s.assetId}`);
    if (s.kind === "cdp" && decimals !== undefined) {
      const level = m18(BigInt(s.owed), BigInt(s.drawCap), decimals);
      if (level !== null) out.push(condition("M-18", level, key, { owed: s.owed, drawCapWholeTokens: s.drawCap }));
    }
    if (s.kind === "lend") {
      // M-19: a Lend Spoke's supply falling more than 10 % within the hour pages.
      const addedKey = `${key}:added`;
      seen.add(addedKey);
      mem.history.record(addedKey, t, BigInt(s.added));
      const drop = mem.history.dropBps(addedKey);
      out.push(condition("M-19", drop > 1_000n ? "page" : "ok", `${key}:withdrawals`, { added: s.added, dropBps: drop.toString(10) }));
    }
  }

  if (prev) out.push(...changes(prev, snap));

  mem.history.retain(seen);
  mem.previous = snap;
  return out;
}

/** M-24 and M-29: what changed since the previous snapshot. */
function changes(prev: ChainSnapshot, snap: ChainSnapshot): Finding[] {
  const out: Finding[] = [];
  const before = <T>(rows: readonly T[], key: (r: T) => string) => new Map(rows.map((r) => [key(r), r]));

  const markets = before(prev.markets, marketKey);
  for (const m of snap.markets) {
    const p = markets.get(marketKey(m));
    if (!p) continue;
    if (p.pauseState !== m.pauseState) out.push(event("M-24", marketKey(m), { market: m.name, pauseState: `${PAUSE_STATE[p.pauseState]} -> ${PAUSE_STATE[m.pauseState]}` }));
    if ((m.breakerReasons & BREAKER.MANUAL) !== 0 && (p.breakerReasons & BREAKER.MANUAL) === 0) out.push(event("M-24", marketKey(m), { market: m.name, manualBreaker: "tripped" }));
  }

  const reserves = before(prev.spokeReserves, reserveKey);
  for (const r of snap.spokeReserves) {
    const p = reserves.get(reserveKey(r));
    if (!p) continue;
    if (p.pauseState !== r.pauseState) out.push(event("M-24", reserveKey(r), { fundingHubPauseState: `${PAUSE_STATE[p.pauseState]} -> ${PAUSE_STATE[r.pauseState]}` }));
    if ((r.breakerReasons & BREAKER.MANUAL) !== 0 && (p.breakerReasons & BREAKER.MANUAL) === 0) out.push(event("M-24", reserveKey(r), { manualBreaker: "tripped" }));
  }

  const hubs = before(prev.hubs, (h) => h.hub);
  for (const h of snap.hubs) {
    const p = hubs.get(h.hub);
    if (!p || p.applicationState === h.applicationState) continue;
    const name = (s: number | null) => (s === null ? "unreadable" : (PAUSE_STATE[s] ?? String(s)));
    out.push(event("M-24", `hub:${h.hub}`, { hub: h.label ?? h.hub, applicationState: `${name(p.applicationState)} -> ${name(h.applicationState)}` }));
  }

  const assets = before(prev.hubAssets, hubAssetKey);
  for (const a of snap.hubAssets) {
    const p = assets.get(hubAssetKey(a));
    if (!p || rateCurveText(p) === rateCurveText(a)) continue;
    out.push(event("M-29", hubAssetKey(a), { before: rateCurveText(p), after: rateCurveText(a) }));
  }
  return out;
}
