// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// What a wallet's older on-chain history tells the rewards: the block of its first interaction, the first block of each
// quest it completed (a Lend supply, borrow, repay, pledge) and the Lend supply it made, in USD. Convex keeps only 30 days
// of logs, so a wallet that began earlier gets these once from the indexer's history (wallet/backfill.ts). The records
// carry blocks, not times: only the few blocks that matter are read for their time afterwards.

import type { ExportRecord } from "@avana/services-common/export";
import { QUEST_OF_LOG } from "./rewards.ts";

export interface BackfillFacts {
  /** The earliest block of any record, or null when there is none. */
  readonly firstBlock: bigint | null;
  /** The earliest block of each quest's log, by quest id. */
  readonly questBlocks: Readonly<Record<string, bigint>>;
  /** Lend supply by the wallet itself, USD at the Hub assets' prices now. */
  readonly supplyUsd: number;
}

export const NO_FACTS: BackfillFacts = { firstBlock: null, questBlocks: {}, supplyUsd: 0 };

export interface SupplyPrice {
  readonly decimals: number;
  readonly priceUsd8: string;
}

/** The wallet an action record belongs to, by the field its event names; null for kinds the quests do not use. */
function actor(r: ExportRecord): string | null {
  const a = r.args as Record<string, unknown>;
  const v = r.kind === "AaveSpoke.Supply" ? a.user : r.kind === "AaveAdapter.Repaid" ? a.borrower : a.wallet;
  return typeof v === "string" ? v.toLowerCase() : null;
}

const min = (a: bigint | null, b: bigint): bigint => (a === null || b < a ? b : a);

/**
 * Folds `records` (newest first, all naming the wallet or its proxies) into `facts`. `supplyPrice` finds the Hub asset of a
 * Lend reserve (`spoke`, `reserveId`) and returns its decimals and price, or null when it is not a Lend reserve.
 */
export function addRecords(
  facts: BackfillFacts,
  records: readonly ExportRecord[],
  wallet: string,
  supplyPrice: (spoke: string, reserveId: string) => SupplyPrice | null,
): BackfillFacts {
  const w = wallet.toLowerCase();
  let firstBlock = facts.firstBlock;
  const questBlocks: Record<string, bigint> = { ...facts.questBlocks };
  let supplyUsd = facts.supplyUsd;
  for (const r of records) {
    const block = BigInt(r.blockNumber);
    firstBlock = min(firstBlock, block);
    const questId = QUEST_OF_LOG[r.kind];
    if (!questId || actor(r) !== w) continue;
    questBlocks[questId] = min(questBlocks[questId] ?? null, block);
    if (r.kind !== "AaveSpoke.Supply") continue;
    const a = r.args as Record<string, unknown>;
    const price = supplyPrice(r.address.toLowerCase(), String(a.reserveId));
    const units = String(a.suppliedAmount);
    if (!price || !/^\d+$/.test(units) || !/^\d+$/.test(price.priceUsd8)) continue;
    supplyUsd += Number((BigInt(units) * BigInt(price.priceUsd8)) / 10n ** BigInt(price.decimals)) / 1e8;
  }
  return { firstBlock, questBlocks, supplyUsd };
}
