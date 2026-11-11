// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Log backfill over RPC, independent of the indexer: account creation events from the manifest's start blocks at
// startup and in every full sweep, and every watched event from the last finalized block after a reconnect.
// Ranges start at 10,000 blocks and halve whenever a provider refuses the range.

import type { AbiEvent, Address, Log, PublicClient } from "viem";

export const INITIAL_CHUNK = 10_000n;
export const MIN_CHUNK = 1n;

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
  let start = fromBlock;
  while (start <= toBlock) {
    const end = start + chunk - 1n < toBlock ? start + chunk - 1n : toBlock;
    try {
      out.push(...(await client.getLogs({ address, event, fromBlock: start, toBlock: end })));
      start = end + 1n;
      if (chunk < INITIAL_CHUNK) chunk *= 2n;
    } catch (err) {
      if (!isRangeRefusal(err) || chunk === MIN_CHUNK) throw err;
      chunk = chunk / 2n > MIN_CHUNK ? chunk / 2n : MIN_CHUNK;
    }
  }
  return out;
}
