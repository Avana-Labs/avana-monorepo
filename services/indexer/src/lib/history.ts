// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Pure rules of the wallet history (EXPORT.md, "Older history"), kept apart from Ponder's virtual modules so they are
// unit-tested: request parsing, the addresses a log names, and closing a newest-first page at a block boundary.

import { HISTORY_MAX_RECORDS } from "@avana/services-common";

export interface HistoryRequest {
  readonly chainId: number;
  readonly wallet: `0x${string}`;
  /** Exclusive upper block; null for the newest page. */
  readonly before: bigint | null;
  readonly limit: number;
}

/** Parses `chainId`, `wallet`, `before` and `limit`; returns the 400 message on a malformed request. */
export function parseHistoryRequest(q: { chainId?: string; wallet?: string; before?: string; limit?: string }): HistoryRequest | { error: string } {
  const limit = q.limit ?? String(HISTORY_MAX_RECORDS);
  if (!/^\d+$/.test(q.chainId ?? "") || !/^\d+$/.test(limit) || (q.before !== undefined && !/^\d+$/.test(q.before))) {
    return { error: "chainId, before and limit are decimal integers" };
  }
  if (!/^0x[0-9a-fA-F]{40}$/.test(q.wallet ?? "")) return { error: "wallet is a 20-byte address" };
  const n = Number(limit);
  if (n < 1 || n > HISTORY_MAX_RECORDS) return { error: `limit must be 1..${HISTORY_MAX_RECORDS}` };
  return { chainId: Number(q.chainId), wallet: q.wallet!.toLowerCase() as `0x${string}`, before: q.before === undefined ? null : BigInt(q.before), limit: n };
}

const ADDRESS = /^0x[0-9a-f]{40}$/;

/** Every distinct address among a log's normalised arguments (lower-case strings), at any depth. */
export function partiesOf(args: unknown): `0x${string}`[] {
  const out = new Set<`0x${string}`>();
  const walk = (v: unknown) => {
    if (typeof v === "string") {
      if (ADDRESS.test(v)) out.add(v as `0x${string}`);
    } else if (Array.isArray(v)) v.forEach(walk);
    else if (v !== null && typeof v === "object") Object.values(v).forEach(walk);
  };
  walk(args);
  return [...out];
}

/**
 * Closes a newest-first page at a block boundary. `rows` are in descending (block, logIndex) order and hold at most
 * `limit` rows; when the page is full its oldest block may be cut, so that block is dropped unless it is the only one,
 * in which case the caller reads it whole (`wholeBlock`). `next` is the `before` of the following page: the oldest
 * block served, or null when the page was not full (nothing older).
 */
export function closeHistoryPage<R extends { readonly blockNumber: bigint }>(rows: readonly R[], limit: number): { rows: R[]; next: bigint | null; wholeBlock: bigint | null } {
  if (rows.length < limit) return { rows: [...rows], next: null, wholeBlock: null };
  const oldest = rows[rows.length - 1]!.blockNumber;
  const complete = rows.filter((r) => r.blockNumber > oldest);
  if (complete.length > 0) return { rows: complete, next: oldest + 1n, wholeBlock: null };
  return { rows: [], next: oldest, wholeBlock: oldest };
}
