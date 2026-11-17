// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Log backfill over RPC, independent of the indexer: account creation events from the manifest's start blocks at
// startup and in every full sweep, and every watched event from the last finalized block after a reconnect.
// Ranges start at 10,000 blocks and halve whenever a provider refuses the range; after a refusal they grow back only
// up to half the refused size, so a provider that caps the range is not asked for a refused range every other call.

import type { AbiEvent, Address, Log, PublicClient } from "viem";

export const INITIAL_CHUNK = 10_000n;
export const MIN_CHUNK = 1n;

/**
 * Where a provider's next incremental sweep starts: its finalized block read before the sweep (logs at or below it
 * never change), or the head the sweep read to when that is lower. A lagging load-balanced node can answer a head below
 * the finalized block another node gave, and the blocks between them would otherwise wait for the daily full sweep.
 */
export function nextSweepFrom(finalized: bigint, through: bigint): bigint {
  return finalized < through ? finalized : through;
}

/** Errors by which providers refuse a range as too large or too many results. */
export function isRangeRefusal(err: unknown): boolean {
  return err instanceof Error && /range|too many|limit exceeded|more than|response size|query returned/i.test(err.message);
}

/** Reads `event` logs of `address` over [fromBlock, toBlock] in chunks; a chunk refused as too large is halved and retried. */
export async function getLogsChunked<E extends AbiEvent>(
  client: PublicClient,
  address: Address | Address[],
  event: E,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<Log[]> {
  const out: Log[] = [];
  let chunk = INITIAL_CHUNK;
  // The largest range not yet refused in this read.
  let ceiling = INITIAL_CHUNK;
  let start = fromBlock;
  while (start <= toBlock) {
    const end = start + chunk - 1n < toBlock ? start + chunk - 1n : toBlock;
    try {
      out.push(...(await client.getLogs({ address, event, fromBlock: start, toBlock: end })));
      start = end + 1n;
      if (chunk < ceiling) chunk = chunk * 2n < ceiling ? chunk * 2n : ceiling;
    } catch (err) {
      if (!isRangeRefusal(err) || chunk === MIN_CHUNK) throw err;
      chunk = chunk / 2n > MIN_CHUNK ? chunk / 2n : MIN_CHUNK;
      ceiling = chunk;
    }
  }
  return out;
}
