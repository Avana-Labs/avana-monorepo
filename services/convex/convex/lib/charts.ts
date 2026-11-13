// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Turns stored series buckets into the app's chart points and quick-stat deltas. A missing bucket repeats the last
// sampled value (nothing changed or no block was sampled) and counts 0 for summed pool metrics (nothing traded).
// The last point is the current row, so a chart ends at the value the page header shows.

import type { DecimalString } from "@avana/services-common/export";
import {
  type Resolution,
  type SeriesScopeKind,
  RESOLUTION_SECONDS,
  bucketStart,
  bucketsBetween,
  dayLabel,
  mergeRule,
  mergeValues,
} from "@avana/services-common/series";
import { compactUsd, pct } from "./format.ts";
import type { DaySeries, MarketSnapshotRow, QuickStat } from "./uiTypes.ts";

export type Values = Readonly<Record<string, DecimalString>>;

export interface StoredPoint {
  readonly bucketStart: number;
  readonly source: "live" | "history";
  readonly values: Values;
}

export type RangeId = "1D" | "1W" | "1M" | "3M" | "1Y" | "ALL";

export const RANGE_DAYS: Readonly<Record<Exclude<RangeId, "ALL">, number>> = { "1D": 1, "1W": 7, "1M": 30, "3M": 90, "1Y": 365 };

/** One value map per bucket: history first, then the live bucket, merged by the scope's rules. */
export function combineSources(kind: SeriesScopeKind, points: readonly StoredPoint[]): Map<number, Values> {
  const out = new Map<number, Values>();
  const ordered = [...points].sort((a, b) => a.bucketStart - b.bucketStart || (a.source === b.source ? 0 : a.source === "history" ? -1 : 1));
  for (const p of ordered) {
    const prev = out.get(p.bucketStart);
    out.set(p.bucketStart, prev ? mergeValues(kind, prev, p.values) : p.values);
  }
  return out;
}

/** Every bucket from the first known one (or `from`, if later) to `to`, with gaps filled per metric rule. */
export function filledBuckets(kind: SeriesScopeKind, byBucket: ReadonlyMap<number, Values>, from: number, to: number, resolution: Resolution): { t: number; values: Values }[] {
  const starts = [...byBucket.keys()].sort((a, b) => a - b);
  const first = starts[0];
  if (first === undefined) return [];
  const out: { t: number; values: Values }[] = [];
  let prev: Values | undefined;
  for (const t of starts) if (t < bucketStart(from, resolution)) prev = byBucket.get(t);
  for (const t of bucketsBetween(Math.max(from, first), to, resolution)) {
    const hit = byBucket.get(t);
    if (hit) {
      out.push({ t, values: hit });
      prev = hit;
    } else if (prev) {
      const filled: Record<string, DecimalString> = {};
      for (const [metric, value] of Object.entries(prev)) filled[metric] = mergeRule(kind, metric) === "sum" ? "0" : value;
      out.push({ t, values: filled });
      prev = filled;
    }
  }
  return out;
}

/** Daily chart points for a range; `ALL` starts at the first bucket. Today's point is the live value. */
export function daySeries(
  id: string,
  label: string,
  days: readonly { t: number; values: Values }[],
  metric: (v: Values) => number,
  range: RangeId,
  now: number,
  live: number | null,
): DaySeries {
  const today = bucketStart(now, "day");
  const from = range === "ALL" ? -Infinity : today - (RANGE_DAYS[range] - 1) * RESOLUTION_SECONDS.day;
  const points = days.filter((d) => d.t >= from && d.t < today).map((d) => ({ t: dayLabel(d.t), v: metric(d.values) }));
  if (live !== null) points.push({ t: dayLabel(today), v: live });
  return { id, label, points };
}

/** The value of a series as of `at` (the last bucket starting at or before it), or null before the first. */
export function valueAt(byBucket: ReadonlyMap<number, Values>, at: number): Values | null {
  let best: number | undefined;
  for (const t of byBucket.keys()) if (t <= at && (best === undefined || t > best)) best = t;
  return best === undefined ? null : byBucket.get(best)!;
}

/** Sum of summed metrics over the buckets in `[from, to)`, e.g. 24 h of pool volume. */
export function sumOver(byBucket: ReadonlyMap<number, Values>, metric: string, from: number, to: number): bigint {
  let total = 0n;
  for (const [t, v] of byBucket) if (t >= from && t < to && v[metric] !== undefined) total += BigInt(v[metric]!);
  return total;
}

const delta = (curr: number, prev: number | undefined): QuickStat["delta"] => {
  const value = !prev ? 0 : Math.round(((curr - prev) / prev) * 1000) / 10;
  return { value, direction: value > 0 ? "up" : value < 0 ? "down" : "flat", label: "24h" };
};

/**
 * The quick-stat strip: current values and their change against the snapshot 24 hours earlier. Labels follow the
 * page's scope: a pool shows collateral and the debt it backs, a Borrow asset page this Spoke's draw.
 */
export function quickStats(current: MarketSnapshotRow, previous: MarketSnapshotRow | null): QuickStat[] {
  const isPool = current.scope === "pool";
  const stats: QuickStat[] = [
    { id: "supplied", label: isPool ? "Collateral" : "Total Supplied", value: compactUsd(current.suppliedUsd), delta: delta(current.suppliedUsd, previous?.suppliedUsd) },
    {
      id: "borrowed",
      label: isPool ? "Debt Backed" : current.scope === "asset" ? "Borrowed via this Spoke" : "Total Borrowed",
      value: compactUsd(current.borrowedUsd),
      delta: delta(current.borrowedUsd, previous?.borrowedUsd),
    },
    { id: "available", label: isPool ? "Cap Headroom" : "Available Liquidity", value: compactUsd(current.availableUsd), delta: delta(current.availableUsd, previous?.availableUsd) },
    { id: "utilization", label: isPool ? "LTV" : "Utilization", value: pct(current.utilizationPct), delta: delta(current.utilizationPct, previous?.utilizationPct) },
  ];
  if (!isPool) stats.push({ id: "supplyApy", label: "Supply APY", value: pct(current.supplyApyPct), delta: delta(current.supplyApyPct, previous?.supplyApyPct) });
  stats.push({ id: "borrowApy", label: isPool ? "Borrow APR" : "Borrow APR (base)", value: pct(current.borrowAprPct), delta: delta(current.borrowAprPct, previous?.borrowAprPct) });
  if (current.reserveFactorPct !== undefined) stats.push({ id: "reserveFactor", label: "Reserve Factor", value: `${Math.round(current.reserveFactorPct)}%`, delta: delta(0, undefined) });
  return stats;
}
