// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The candidate cache: one entry per PositionProxy, keyed `chainId + Spoke + proxy` as in the indexer. Cached
// values only choose what to read; every decision re-reads the chain at a pinned block. The deciding flag is
// cleared in `finally`, so a failure can never leave an account stuck; the pending flag follows the transaction.

import type { Address } from "viem";
import { accountKey } from "@avana/services-common";

export interface CachedAccount {
  readonly chainId: number;
  readonly spoke: Address;
  readonly proxy: Address;
  readonly wallet: Address;
  readonly marketId: bigint;
  readonly vaultToken: Address;
  /** Debt reserves with non-zero debt at the last read. */
  debtReserveIds: bigint[];
  lastHealthFactor: bigint | null;
  lastReadBlock: bigint;
  /** First block at which the account was read below HF 1 in the current episode; null when healthy. */
  liquidatableSince: bigint | null;
  /** Set while this instance is deciding on the account (cleared in `finally`). */
  deciding: boolean;
  /** Hash of this instance's pending transaction for the account; cleared by the tracker when it is mined, cancelled or expired. */
  pendingTx: `0x${string}` | null;
  /** Seen by the indexer stream, by the RPC log backfill, or both; a one-sided entry raises an alert (REQ-LENS-004). */
  seenBy: { indexer: boolean; rpc: boolean };
}

export class AccountCache {
  private readonly accounts = new Map<string, CachedAccount>();

  upsert(entry: Omit<CachedAccount, "debtReserveIds" | "lastHealthFactor" | "lastReadBlock" | "liquidatableSince" | "deciding" | "pendingTx" | "seenBy">, source: "indexer" | "rpc"): CachedAccount {
    const key = accountKey(entry.chainId, entry.spoke, entry.proxy);
    const existing = this.accounts.get(key);
    if (existing) {
      existing.seenBy[source] = true;
      return existing;
    }
    const fresh: CachedAccount = {
      ...entry,
      debtReserveIds: [],
      lastHealthFactor: null,
      lastReadBlock: 0n,
      liquidatableSince: null,
      deciding: false,
      pendingTx: null,
      seenBy: { indexer: source === "indexer", rpc: source === "rpc" },
    };
    this.accounts.set(key, fresh);
    return fresh;
  }

  get(chainId: number, spoke: Address, proxy: Address): CachedAccount | undefined {
    return this.accounts.get(accountKey(chainId, spoke, proxy));
  }

  ofChain(chainId: number): CachedAccount[] {
    return [...this.accounts.values()].filter((a) => a.chainId === chainId);
  }

  /** Accounts the two discovery sources disagree on; each is kept (the union) and reported. */
  oneSided(chainId: number): CachedAccount[] {
    return this.ofChain(chainId).filter((a) => !(a.seenBy.indexer && a.seenBy.rpc));
  }

  /** Records a read: tracks when an account first fell below HF 1, for shard takeover and M-09. */
  recordRead(a: CachedAccount, healthFactor: bigint, block: bigint): void {
    a.lastHealthFactor = healthFactor;
    a.lastReadBlock = block;
    if (healthFactor < 10n ** 18n) a.liquidatableSince ??= block;
    else a.liquidatableSince = null;
  }

  /** In flight: a decision is running or a transaction of this instance is pending for the account. */
  inFlight(a: CachedAccount): boolean {
    return a.deciding || a.pendingTx !== null;
  }

  /** Runs `fn` with the account marked as deciding; returns undefined without running when it is in flight. */
  async exclusive<T>(a: CachedAccount, fn: () => Promise<T>): Promise<T | undefined> {
    if (this.inFlight(a)) return undefined;
    a.deciding = true;
    try {
      return await fn();
    } finally {
      a.deciding = false;
    }
  }
}
