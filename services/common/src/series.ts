// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Chart series shared by the indexer (writer), its series export and Convex (reader): scope keys, UTC buckets,
// per-metric merge rules and gap filling. Values are decimal strings in the scope's own units; nothing here
// converts to USD or percent.

import type { DecimalString } from "./export.ts";

/** Hourly buckets feed the 1D and 1W ranges; daily buckets feed every longer range. */
export type Resolution = "hour" | "day";

export const RESOLUTION_SECONDS: Readonly<Record<Resolution, number>> = { hour: 3_600, day: 86_400 };

/**
 * The scope a series belongs to. Each number has one owner (services/README.md, "Scopes"):
 * - `hubAsset`: one asset of one Hub, `chainId:hub:assetId`.
 * - `hubAssetSpoke`: one Spoke's slice of a Hub asset, `chainId:hub:assetId:spoke`.
 * - `market`: one collateral market, `chainId:marketId`.
 * - `marketReserve`: debt one market backs in one CDP debt reserve, `chainId:marketId:spoke:reserveId`.
 * - `pool`: one AMM pool's swaps and liquidity, `chainId:pool`.
 * - `position`: one account (PositionProxy), `chainId:spoke:proxy`.
 * - `creditLine`: one Hub-to-Hub credit line, `chainId:fundingHub:assetId:spoke`; its draw is the `hubAssetSpoke`
 *   series of the same Hub asset and Spoke.
 */
export type SeriesScopeKind = "hubAsset" | "hubAssetSpoke" | "market" | "marketReserve" | "pool" | "position" | "creditLine";

/** How a bucket combines two observations of one metric. */
export type MergeRule = "first" | "last" | "sum" | "max" | "min";

/**
 * Sampled scopes keep the first observation of a bucket (the first sampled block at or after the bucket start), so
 * every scope of one bucket is read at the same block and the identities of the scope model hold point by point.
 * Pool buckets aggregate swaps: volumes and fees add up, prices and liquidity keep the last swap.
 */
export const MERGE_RULES: Readonly<Record<SeriesScopeKind, Readonly<Record<string, MergeRule>>>> = {
  hubAsset: {},
  hubAssetSpoke: {},
  market: {},
  marketReserve: {},
  position: {},
  creditLine: {},
  pool: {
    volume0: "sum",
    volume1: "sum",
    fees0: "sum",
    fees1: "sum",
    swaps: "sum",
    mints: "sum",
    burns: "sum",
    liquidityAdded: "sum",
    liquidityRemoved: "sum",
    sqrtPriceX96: "last",
    tick: "last",
    liquidity: "last",
    tickHigh: "max",
    tickLow: "min",
  },
};

/** Rule of a metric; any metric not listed for the scope keeps the bucket's first observation. */
export function mergeRule(kind: SeriesScopeKind, metric: string): MergeRule {
  return MERGE_RULES[kind][metric] ?? "first";
}

/** Joins key parts into a scope key; addresses lower-case, integers in decimal. */
export function scopeKey(...parts: readonly (string | number | bigint)[]): string {
  return parts.map((p) => (typeof p === "string" ? p.toLowerCase() : p.toString(10))).join(":");
}

/** Start of the UTC bucket holding `timestampSeconds`. */
export function bucketStart(timestampSeconds: number | bigint, resolution: Resolution): number {
  const t = Number(timestampSeconds);
  if (!Number.isSafeInteger(t) || t < 0) throw new Error(`timestamp ${timestampSeconds} is not a non-negative integer`);
  const size = RESOLUTION_SECONDS[resolution];
  return t - (t % size);
}

/** End of a bucket (exclusive): the first second of the next bucket. */
export function bucketEnd(start: number, resolution: Resolution): number {
  return start + RESOLUTION_SECONDS[resolution];
}

/** `YYYY-MM-DD` (UTC) of a bucket start, the day label the app's charts use. */
export function dayLabel(startSeconds: number): string {
  return new Date(startSeconds * 1000).toISOString().slice(0, 10);
}

/** Every bucket start from the bucket of `from` through the bucket of `to`, inclusive. */
export function bucketsBetween(from: number, to: number, resolution: Resolution): number[] {
  const out: number[] = [];
  const size = RESOLUTION_SECONDS[resolution];
  for (let t = bucketStart(from, resolution); t <= bucketStart(to, resolution); t += size) out.push(t);
  return out;
}

function pick(rule: MergeRule, a: DecimalString, b: DecimalString): DecimalString {
  switch (rule) {
    case "first":
      return a;
    case "last":
      return b;
    case "sum":
      return (BigInt(a) + BigInt(b)).toString(10);
    case "max":
      return BigInt(a) >= BigInt(b) ? a : b;
    case "min":
      return BigInt(a) <= BigInt(b) ? a : b;
  }
}

/** Combines a stored bucket with a new observation, metric by metric, by the scope's merge rules. */
export function mergeValues(
  kind: SeriesScopeKind,
  stored: Readonly<Record<string, DecimalString>>,
  incoming: Readonly<Record<string, DecimalString>>,
): Record<string, DecimalString> {
  const out: Record<string, DecimalString> = { ...stored };
  for (const [metric, value] of Object.entries(incoming)) {
    const prev = stored[metric];
    out[metric] = prev === undefined ? value : pick(mergeRule(kind, metric), prev, value);
  }
  return out;
}

/** One stored point of one metric. */
export interface SeriesPoint {
  /** Bucket start, unix seconds. */
  readonly t: number;
  readonly v: DecimalString;
  /** Block the value was read at, or the last block that changed a summed bucket. */
  readonly block: DecimalString;
}

/**
 * Returns one point per bucket from `from` to `to`. A missing bucket of a sampled metric repeats the previous
 * value (the state did not change, or no block was sampled); a missing bucket of a summed metric is 0 (nothing
 * happened). Buckets before the first known point are left out, so a series starts at its scope's listing.
 */
export function fillGaps(
  points: readonly SeriesPoint[],
  rule: MergeRule,
  from: number,
  to: number,
  resolution: Resolution,
): SeriesPoint[] {
  const byT = new Map(points.map((p) => [p.t, p]));
  const sorted = [...points].sort((a, b) => a.t - b.t);
  const out: SeriesPoint[] = [];
  let prev: SeriesPoint | undefined = sorted.filter((p) => p.t < bucketStart(from, resolution)).at(-1);
  for (const t of bucketsBetween(from, to, resolution)) {
    const hit = byT.get(t);
    if (hit) {
      out.push(hit);
      prev = hit;
    } else if (rule === "sum") {
      if (prev !== undefined || sorted.some((p) => p.t < t)) out.push({ t, v: "0", block: prev?.block ?? "0" });
    } else if (prev !== undefined) {
      out.push({ t, v: prev.v, block: prev.block });
    }
  }
  return out;
}

/** One closed bucket of one scope, as the indexer's series export serves it. */
export interface SeriesRecord {
  readonly chainId: number;
  readonly scopeKind: SeriesScopeKind;
  readonly scopeKey: string;
  readonly resolution: Resolution;
  readonly bucketStart: number;
  readonly blockNumber: DecimalString;
  readonly values: Readonly<Record<string, DecimalString>>;
}

/**
 * A page of closed buckets: every bucket whose end is at or before `next.throughTime`, which never passes the
 * timestamp of the chain's finalized block. The cursor is a time, so a page never splits a bucket end.
 */
export interface SeriesExportPage {
  readonly schemaVersion: number;
  readonly chainId: number;
  readonly after: { readonly throughTime: number } | null;
  readonly next: { readonly throughTime: number };
  readonly records: readonly SeriesRecord[];
  readonly finalizedBlock: DecimalString;
  readonly pageHash: `0x${string}`;
}

/** Bumped on any change to a series metric's name or unit; Convex rebuilds series of an unknown version. */
export const SERIES_SCHEMA_VERSION = 1;
