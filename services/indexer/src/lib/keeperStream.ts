// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Pure rules of the keeper stream (EXPORT.md, "Keeper stream"), kept apart from Ponder's virtual modules so they are
// unit-tested: request parsing, the served range and closing a page at a block boundary.

import { KEEPER_STREAM_MAX_RECORDS, type KeeperStreamCursor } from "@avana/services-common";

export interface StreamRequest {
  readonly chainId: number;
  readonly after: { readonly block: bigint; readonly hash: `0x${string}` } | null;
  readonly limit: number;
}

/** Parses `chainId`, `after`, `afterHash` and `limit`; returns the 400 message on a malformed request. */
export function parseStreamRequest(q: { chainId?: string; after?: string; afterHash?: string; limit?: string }): StreamRequest | { error: string } {
  const limit = q.limit ?? String(KEEPER_STREAM_MAX_RECORDS);
  if (!/^\d+$/.test(q.chainId ?? "") || !/^\d+$/.test(limit)) return { error: "chainId and limit are decimal integers" };
  if ((q.after === undefined) !== (q.afterHash === undefined)) return { error: "after and afterHash go together" };
  if (q.after !== undefined && (!/^\d+$/.test(q.after) || !/^0x[0-9a-fA-F]{64}$/.test(q.afterHash!))) {
    return { error: "after is a decimal block number and afterHash its 32-byte hash" };
  }
  const n = Number(limit);
  if (n < 1 || n > KEEPER_STREAM_MAX_RECORDS) return { error: `limit must be 1..${KEEPER_STREAM_MAX_RECORDS}` };
  return {
    chainId: Number(q.chainId),
    after: q.after === undefined ? null : { block: BigInt(q.after), hash: q.afterHash!.toLowerCase() as `0x${string}` },
    limit: n,
  };
}

/**
 * The highest block the stream may serve: the last block the indexer has fully handled. The `Progress` row of block
 * N may be written before N's logs are handled, so N itself is not served (as in the export, without its finality cap).
 */
export function streamableThrough(progressBlock: bigint | null): bigint {
  return progressBlock === null ? -1n : progressBlock - 1n;
}

/** A cursor continues the canonical chain when the hash it names is the hash the chain now has at that block. */
export function cursorCanonical(after: KeeperStreamCursor | { block: bigint; hash: string }, canonicalHash: string): boolean {
  return after.hash.toLowerCase() === canonicalHash.toLowerCase();
}

/**
 * Closes a page at a block boundary. `rows` are in (block, logIndex) order and hold at most `limit` rows; when the
 * page is full its last block may be cut, so that block is dropped unless it is the only one, in which case the
 * caller reads it whole (`wholeBlock`).
 */
export function closePage<R extends { readonly blockNumber: bigint }>(rows: readonly R[], through: bigint, limit: number): { rows: R[]; toBlock: bigint; wholeBlock: bigint | null } {
  if (rows.length < limit) return { rows: [...rows], toBlock: through, wholeBlock: null };
  const last = rows[rows.length - 1]!.blockNumber;
  const complete = rows.filter((r) => r.blockNumber < last);
  if (complete.length > 0) return { rows: complete, toBlock: last - 1n, wholeBlock: null };
  return { rows: [], toBlock: last, wholeBlock: last };
}
