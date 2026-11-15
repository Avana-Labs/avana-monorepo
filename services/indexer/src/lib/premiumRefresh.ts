// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The refresh list of one Spoke (EXPORT.md, "Risk premium refresh"), kept apart from Ponder's virtual modules so it is
// unit-tested: an attributed account with drawn debt whose last premium update is older than the Spoke's last
// collateral-risk change, or that has none, needs `updateUserRiskPremium`.

export interface Position {
  readonly blockNumber: bigint;
  readonly logIndex: number;
}

export interface RefreshCandidate {
  readonly proxy: `0x${string}`;
  /** Σ drawn shares over the account's debt reserves, from the indexed Borrow, Repay and LiquidationCall logs. */
  readonly drawnShares: bigint;
  /** The log of the account's last `UpdateUserRiskPremium`, or null when none was indexed. */
  readonly premiumAt: Position | null;
}

const before = (a: Position, b: Position) => a.blockNumber < b.blockNumber || (a.blockNumber === b.blockNumber && a.logIndex < b.logIndex);

/** The latest of the reserves' collateral-risk changes, or null when none changed. */
export function lastRiskChange(changes: readonly (Position | null)[]): Position | null {
  let last: Position | null = null;
  for (const c of changes) if (c && (last === null || before(last, c))) last = c;
  return last;
}

/** Proxies to refresh, sorted; empty when no collateral risk on the Spoke has changed. */
export function refreshList(change: Position | null, accounts: readonly RefreshCandidate[]): `0x${string}`[] {
  if (change === null) return [];
  return accounts
    .filter((a) => a.drawnShares > 0n && (a.premiumAt === null || before(a.premiumAt, change)))
    .map((a) => a.proxy.toLowerCase() as `0x${string}`)
    .sort();
}
