// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// What survives a restart: the open alerts (so they are not sent again), the keeper feed, and each probe's state (the
// events probe's next block, so events during downtime are read on catch-up; the hour windows; the last-seen Safes,
// issuer probes and frontend, so a change made while the monitor was down is still reported). One JSON file, written
// to a temporary name and renamed over the old one, so a crash mid-write leaves the previous state intact.

import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";

export const STATE_VERSION = 1;

export interface SavedState {
  readonly version: number;
  readonly savedAt: number;
  readonly book: unknown;
  readonly keeper: unknown;
  /** Safe signer liveness answers of the last periods. */
  readonly liveness?: unknown;
  /** chainId → probe name → that probe's saved state. */
  readonly probes: Readonly<Record<string, Readonly<Record<string, unknown>>>>;
}

/** JSON with bigints, Maps and Sets kept (tagged), so state round-trips exactly. */
export function encode(value: unknown): string {
  return JSON.stringify(value, (_, v) => {
    if (typeof v === "bigint") return { $big: v.toString(10) };
    if (v instanceof Map) return { $map: [...v.entries()] };
    if (v instanceof Set) return { $set: [...v.values()] };
    return v;
  });
}

export function decode(text: string): unknown {
  return JSON.parse(text, (_, v) => {
    if (v && typeof v === "object" && !Array.isArray(v)) {
      if (typeof v.$big === "string" && Object.keys(v).length === 1) return BigInt(v.$big);
      if (Array.isArray(v.$map) && Object.keys(v).length === 1) return new Map(v.$map);
      if (Array.isArray(v.$set) && Object.keys(v).length === 1) return new Set(v.$set);
    }
    return v;
  });
}

export interface StateStore {
  load(): SavedState | null;
  save(state: SavedState): void;
}

/** A state file; a missing file is a first start, a file of another version or unreadable stops the process. */
export function fileStateStore(path: string): StateStore {
  return {
    load() {
      if (!existsSync(path)) return null;
      const s = decode(readFileSync(path, "utf8")) as SavedState;
      if (s.version !== STATE_VERSION) throw new Error(`state file ${path} has version ${s.version}, not ${STATE_VERSION}; move it aside to start fresh`);
      return s;
    },
    save(state) {
      const tmp = `${path}.tmp`;
      writeFileSync(tmp, encode(state), "utf8");
      renameSync(tmp, path);
    },
  };
}

/** The parts that hold state, as `collect` and `apply` need them. */
export interface Stateful {
  readonly book: { save(): unknown; restore(saved: never): void };
  readonly feed: { save(): unknown; restore(saved: never): void };
  readonly liveness?: { save(): unknown; restore(saved: never): void };
  /** chainId → that chain's probes. */
  readonly probes: ReadonlyMap<number, readonly { readonly name: string; save?(): unknown; restore?(state: unknown): void }[]>;
}

export function collect(parts: Stateful, now: number): SavedState {
  const probes: Record<string, Record<string, unknown>> = {};
  for (const [chainId, ps] of parts.probes) {
    probes[String(chainId)] = Object.fromEntries(ps.filter((p) => p.save).map((p) => [p.name, p.save!()]));
  }
  return { version: STATE_VERSION, savedAt: now, book: parts.book.save(), keeper: parts.feed.save(), ...(parts.liveness ? { liveness: parts.liveness.save() } : {}), probes };
}

/** Restores a saved state; a probe or chain no longer configured is skipped, a new one starts fresh. */
export function apply(parts: Stateful, saved: SavedState): void {
  (parts.book.restore as (s: unknown) => void).call(parts.book, saved.book);
  (parts.feed.restore as (s: unknown) => void).call(parts.feed, saved.keeper);
  if (parts.liveness && saved.liveness) (parts.liveness.restore as (s: unknown) => void).call(parts.liveness, saved.liveness);
  for (const [chainId, ps] of parts.probes) {
    const mine = saved.probes[String(chainId)] ?? {};
    for (const p of ps) if (p.restore && p.name in mine) p.restore(mine[p.name]);
  }
}
