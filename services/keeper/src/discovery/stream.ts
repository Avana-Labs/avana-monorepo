// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// New heads and live events. Heads drive the per-block scan; events from the indexer stream only refresh the cache.
// A head watchdog reconnects when no head arrives for 3 block times, and every reconnect (of the indexer stream or
// an RPC subscription) re-reads logs from the last finalized block before new blocks are processed, so nothing
// missed during an outage is lost.

import type { ChainInfo } from "@avana/services-common";

/** The event kinds of the indexer stream (services/README.md, Discovery), shared with the indexer that serves them. */
export {
  KEEPER_ACCOUNT_KINDS as ACCOUNT_EVENTS,
  KEEPER_MARKET_KINDS as MARKET_EVENTS,
  KEEPER_PENDING_KINDS as PENDING_EVENTS,
  KEEPER_STATUS_KINDS as STATUS_EVENTS,
} from "@avana/services-common";

export interface Head {
  readonly number: bigint;
  readonly hash: `0x${string}`;
  readonly parentHash: `0x${string}`;
  readonly timestamp: bigint;
}

/** Calls `onStall` when no head arrived for 3 block times; the caller reconnects and backfills. */
export function headWatchdog(chain: ChainInfo, onStall: () => void) {
  const limitMs = 3 * chain.blockTimeSeconds * 1000;
  let timer: NodeJS.Timeout | undefined;
  const arm = () => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(onStall, limitMs);
  };
  arm();
  return { seen: arm, stop: () => timer && clearTimeout(timer) };
}

/**
 * Detects a reorg from consecutive heads: a head whose parent is not the previous head's hash (at height − 1)
 * means blocks were replaced. The keeper then re-reads touched accounts, returns removed transactions to pending,
 * resyncs the nonce and rolls the cache back with the indexer to the common ancestor.
 */
export function isReorg(previous: Head | null, next: Head): boolean {
  if (previous === null) return false;
  if (next.number === previous.number + 1n) return next.parentHash !== previous.hash;
  return next.number <= previous.number;
}
