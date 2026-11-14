// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The keeper's event stream from the indexer (services/README.md, Keeper > Discovery and caching). Unlike the
// export, it serves blocks at the chain head, which a reorg can still remove: every page names the hash of its last
// block, and the request names the hash of the block it continues from, so the indexer refuses a cursor that left the
// canonical chain and the keeper rewinds to the finalized block. The rules are in services/indexer/EXPORT.md
// ("Keeper stream"); these types are the wire format.

import type { DecimalString, ExportRecord, HexString } from "./export.ts";

/** Bumped on any change to the page fields or the record kinds below. */
export const KEEPER_STREAM_VERSION = 1;

/** At most this many records per page; a page never splits a block, so a larger block is served whole. */
export const KEEPER_STREAM_MAX_RECORDS = 1_000;

/** Events that add or refresh an account (services/README.md, Discovery: live updates). */
export const KEEPER_ACCOUNT_KINDS = [
  "AaveAdapter.UserProxyCreated",
  "ProxyManager.ProxyDeployed",
  "AaveAdapter.CollateralAdded",
  "AaveAdapter.Borrowed",
  "AaveAdapter.Repaid",
  "AaveAdapter.CollateralWithdrawn",
  "LPVaultSwap.LiquidationSettled",
  "AaveSpoke.Supply",
  "AaveSpoke.Borrow",
  "AaveSpoke.Repay",
  "AaveSpoke.Withdraw",
  "AaveSpoke.LiquidationCall",
  "AaveSpoke.ReportDeficit",
] as const;
/** Events that refresh a market or a debt reserve. */
export const KEEPER_MARKET_KINDS = ["LPOracle.PriceStateChanged", "DebtOracle.DebtPriceStateChanged", "LPOracle.GraceStarted", "DebtOracle.DebtGraceStarted"] as const;
/** Events that drive `settlePending`. */
export const KEEPER_PENDING_KINDS = ["Collateralization.SeizureReconciled", "Collateralization.PendingSettled"] as const;
/** Events that change the keeper's own status. */
export const KEEPER_STATUS_KINDS = ["LPVaultSwap.KeeperAdded", "LPVaultSwap.KeeperRemoved", "MarketRegistry.AddressFrozen", "MarketRegistry.AddressUnfrozen"] as const;

/** Every kind the stream serves; any other `event_log` row is left out. */
export const KEEPER_STREAM_KINDS: readonly string[] = [...KEEPER_ACCOUNT_KINDS, ...KEEPER_MARKET_KINDS, ...KEEPER_PENDING_KINDS, ...KEEPER_STATUS_KINDS];

/** The last block a page covered, with its hash as the indexer held it. */
export interface KeeperStreamCursor {
  readonly block: DecimalString;
  readonly hash: HexString;
}

export interface KeeperStreamPage {
  readonly version: number;
  readonly chainId: number;
  /** The cursor the request named; null for a read from the start blocks. */
  readonly after: KeeperStreamCursor | null;
  /** The next request's cursor: the page's last block and its hash. */
  readonly next: KeeperStreamCursor;
  /** Inclusive block range; every streamed record of every block in it is in this page. */
  readonly fromBlock: DecimalString;
  readonly toBlock: DecimalString;
  readonly records: readonly ExportRecord[];
  /** The last block the indexer has fully handled; the page never passes it. More pages follow while `toBlock` is below it. */
  readonly indexedBlock: DecimalString;
  readonly finalizedBlock: DecimalString;
}

/** 409 body: the cursor's block is no longer canonical. The keeper rewinds to `finalized` and re-reads from there. */
export interface KeeperStreamReorg {
  readonly reorg: true;
  readonly chainId: number;
  readonly finalized: KeeperStreamCursor;
}
