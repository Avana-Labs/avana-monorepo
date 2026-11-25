// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Export page helpers the import needs beyond the checks in `@avana/export` (README, "Scheduled pull", step 4), and
// the block times of history records, which the history endpoint does not carry.

import type { ExportPage } from "@avana/services-common/export";

/** Block timestamps of a page in milliseconds, for the `at` of each record. */
export function blockTimes(page: ExportPage): Map<string, number> {
  return new Map(page.blocks.map((b) => [b.number, Number(b.timestamp) * 1000]));
}

export interface BlockRef {
  readonly number: string;
  readonly hash: string;
}

export interface BlockTime extends BlockRef {
  readonly timestampMs: number;
}

export interface BlockTimeSource {
  /** Stored times of these block numbers (any hash). */
  cached(numbers: readonly string[]): Promise<readonly BlockTime[]>;
  /** The block's time from the chain. */
  fetch(block: BlockRef): Promise<BlockTime>;
  store(rows: readonly BlockTime[]): Promise<void>;
}

/** Blocks read from the chain at once. */
const FETCH_CONCURRENCY = 10;

/**
 * The time of each block in milliseconds, by block number: a stored time is used when its hash is the block's, every
 * other block is read once and stored.
 */
export async function resolveBlockTimes(blocks: readonly BlockRef[], source: BlockTimeSource): Promise<Map<string, number>> {
  const wanted = new Map(blocks.map((b) => [b.number, b]));
  const out = new Map<string, number>();
  if (wanted.size === 0) return out;
  for (const c of await source.cached([...wanted.keys()])) {
    if (wanted.get(c.number)?.hash === c.hash) out.set(c.number, c.timestampMs);
  }
  const missing = [...wanted.values()].filter((b) => !out.has(b.number));
  const fetched: BlockTime[] = [];
  for (let i = 0; i < missing.length; i += FETCH_CONCURRENCY) {
    fetched.push(...(await Promise.all(missing.slice(i, i + FETCH_CONCURRENCY).map((b) => source.fetch(b)))));
  }
  for (const f of fetched) out.set(f.number, f.timestampMs);
  if (fetched.length > 0) await source.store(fetched);
  return out;
}
