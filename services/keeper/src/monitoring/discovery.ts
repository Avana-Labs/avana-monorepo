// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// M-30, the keeper's discovery mismatch (services/README.md, Monitoring and alerting). The keeper finds accounts
// through two independent sources, the indexer stream and its own RPC log backfill over both providers, and keeps the
// union (REQ-LENS-004). An account only one source holds, up to the block both have read, warns at once and pages once
// it has stayed one-sided for KEEPER_DISCOVERY_MISMATCH_PAGE_SECONDS (1 hour by default). The alert is one per chain,
// re-sent every block while any account is one-sided; the monitor resolves it when the keeper stops sending it, that
// is once the sources agree. No second-provider confirmation applies: the RPC side already reads both providers.

import { type ChainInfo, accountKey, blocksFor } from "@avana/services-common";
import type { CachedAccount } from "../discovery/accountCache.ts";
import type { Alert } from "./alerts.ts";
import type { Level } from "./signals.ts";

/** Default time an account may stay one-sided before M-30 pages. */
export const DISCOVERY_PAGE_SECONDS = 3_600;

/** Accounts named in the alert detail; the counts cover the rest. */
export const ACCOUNTS_IN_DETAIL = 10;

/**
 * The block both sources have read to: the lower of the RPC backfill's block and the indexer's handled block.
 * Negative while either source has not answered yet, and then nothing is compared.
 */
export function discoveryThrough(rpcThrough: bigint, indexedBlock: bigint): bigint {
  return rpcThrough < indexedBlock ? rpcThrough : indexedBlock;
}

/** M-30 for one account first seen one-sided at `since`: warn at once, page after `pageBlocks`. */
export function m30Level(since: bigint, now: bigint, pageBlocks: bigint): Exclude<Level, "ok"> {
  return now - since >= pageBlocks ? "page" : "warn";
}

export interface DiscoveryResult {
  /** Accounts only the indexer stream holds. */
  readonly indexerOnly: number;
  /** Accounts only the RPC log backfill holds. */
  readonly rpcOnly: number;
  /** The alert to send at this head; null when the sources agree. */
  readonly alert: Alert | null;
}

/** Tracks since when each account has been one-sided on one chain and judges M-30 at each head. */
export class DiscoveryWatch {
  readonly pageBlocks: bigint;
  /** Account key → the first head at which it was seen one-sided in the current episode. */
  readonly #since = new Map<string, bigint>();

  constructor(
    private readonly chain: ChainInfo,
    pageSeconds: number = DISCOVERY_PAGE_SECONDS,
  ) {
    this.pageBlocks = BigInt(blocksFor(chain, pageSeconds));
  }

  /**
   * Judges the accounts one-sided at `head` (`AccountCache.oneSided` up to `through`). An account that is no longer
   * one-sided ends its episode, so a later disagreement counts afresh.
   */
  check(oneSided: readonly CachedAccount[], head: bigint, through: bigint): DiscoveryResult {
    const current = new Map(oneSided.map((a) => [accountKey(a.chainId, a.spoke, a.proxy), a] as const));
    for (const key of this.#since.keys()) if (!current.has(key)) this.#since.delete(key);
    for (const key of current.keys()) if (!this.#since.has(key)) this.#since.set(key, head);

    const indexerOnly = oneSided.filter((a) => a.seenBy.indexer && !a.seenBy.rpc).length;
    const rpcOnly = oneSided.length - indexerOnly;
    if (oneSided.length === 0) return { indexerOnly, rpcOnly, alert: null };

    // Oldest first, so the accounts closest to paging are the ones named.
    const ranked = [...current.entries()]
      .map(([key, a]) => ({ a, since: this.#since.get(key)! }))
      .sort((x, y) => (x.since < y.since ? -1 : x.since > y.since ? 1 : 0));
    const oldest = ranked[0]!.since;
    const named = ranked.slice(0, ACCOUNTS_IN_DETAIL).map(({ a }) => `${a.spoke}:${a.proxy}:${a.seenBy.indexer ? "indexer" : "rpc"}`);
    return {
      indexerOnly,
      rpcOnly,
      alert: {
        signal: "M-30",
        level: m30Level(oldest, head, this.pageBlocks),
        chainId: this.chain.id,
        blockNumber: head,
        subject: "discovery",
        detail: {
          indexerOnly: String(indexerOnly),
          rpcOnly: String(rpcOnly),
          through: through.toString(10),
          oldestSince: oldest.toString(10),
          pageAfterBlocks: this.pageBlocks.toString(10),
          // spoke:proxy:source, where source is the only one that holds the account.
          accounts: named.join(","),
          playbook: "P-08",
        },
      },
    };
  }
}
