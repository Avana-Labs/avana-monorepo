// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Every account the AaveAdapter has deployed, from its `AccountCreated` events, read in block ranges and kept between
// passes. (The Ponder indexer serves the same list once the services step rewires the keeper to the new core.)

import type { Address } from "viem";
import type { Chain } from "./chain.ts";

export interface Account {
  readonly account: Address;
  readonly marketId: bigint;
}

export class AccountSet {
  private readonly seen = new Map<Address, Account>();
  private next: bigint;

  constructor(
    private readonly chain: Chain,
    private readonly adapter: Address,
    fromBlock: bigint,
    private readonly range = 10_000n,
  ) {
    this.next = fromBlock;
  }

  /** Reads new events up to the head and returns every account known. */
  async refresh(): Promise<Account[]> {
    const head = await this.chain.getBlockNumber();
    while (this.next <= head) {
      const to = this.next + this.range - 1n < head ? this.next + this.range - 1n : head;
      for (const a of await this.chain.getAccountCreatedLogs(this.adapter, this.next, to)) this.seen.set(a.account, a);
      this.next = to + 1n;
    }
    return [...this.seen.values()];
  }
}
