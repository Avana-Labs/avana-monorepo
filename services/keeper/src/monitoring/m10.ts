// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// M-10 per market (services/README.md): liquidation reverts by reason in the keeper's simulation, 1 per market per
// hour warns and 3 page. The keeper retries an account every block, so one stuck account would reach 3 within three
// blocks; a revert counts once per account per hour, and a single stuck account is M-09's to escalate. A revert that is
// itself a page (InsufficientProceeds, NoRouteAvailable) stays a page. The alert's subject is the market, so the
// monitor holds one M-10 per market; the account and reason travel in the detail. RouteFailed events and the share
// of collateral seized are counted by the monitor from chain events.

/** Distinct accounts with a revert per market within a sliding window of blocks. */
export class RevertWindow {
  readonly #seen = new Map<string, Map<string, bigint>>();

  constructor(readonly windowBlocks: bigint) {}

  /** Records a revert of `account` in `market` at `block`; returns how many accounts reverted in the window. */
  record(market: string, account: string, block: bigint): number {
    const accounts = this.#seen.get(market) ?? new Map<string, bigint>();
    this.#seen.set(market, accounts);
    for (const [a, b] of accounts) if (block - b >= this.windowBlocks) accounts.delete(a);
    accounts.set(account.toLowerCase(), block);
    return accounts.size;
  }
}

/** 1 account in the hour warns, 3 page; a revert raised as a page stays one. */
export function m10Level(accounts: number, raised: "warn" | "page"): "warn" | "page" {
  return raised === "page" || accounts >= 3 ? "page" : "warn";
}
