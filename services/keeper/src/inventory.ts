// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Inventory reservations per chain and debt asset (Q-336). Each pending transaction reserves the inventory amount
// and top-up bound it may pull from the funding Safe; a new call is sized against the balance minus every open
// reservation, so concurrent liquidations never count on the same funds.

import type { Address } from "viem";
import type { Reservation } from "./types.ts";

export class InventoryBook {
  private readonly open = new Map<string, Reservation[]>();

  reserved(chainId: number, asset: Address): bigint {
    let total = 0n;
    for (const [txKey, list] of this.open) {
      if (!txKey.startsWith(`${chainId}:`)) continue;
      for (const r of list) if (r.asset.toLowerCase() === asset.toLowerCase()) total += r.amount;
    }
    return total;
  }

  /** Free inventory = Safe balance − open reservations; this is also the M-16 float. */
  free(chainId: number, asset: Address, safeBalance: bigint): bigint {
    const f = safeBalance - this.reserved(chainId, asset);
    return f > 0n ? f : 0n;
  }

  /** Reserves for one pending transaction, or returns false without reserving when the free balance is short. */
  reserve(chainId: number, txKey: string, items: readonly Reservation[], balances: (asset: Address) => bigint): boolean {
    for (const r of items) if (this.free(chainId, r.asset, balances(r.asset)) < r.amount) return false;
    this.open.set(`${chainId}:${txKey}`, [...items]);
    return true;
  }

  /** Released when the transaction is mined, replaced by a rebuilt one, cancelled or expired. */
  release(chainId: number, txKey: string): void {
    this.open.delete(`${chainId}:${txKey}`);
  }
}
