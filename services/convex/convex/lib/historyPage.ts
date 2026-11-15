// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Checks a wallet history page from the indexer (services/indexer/EXPORT.md, "Older history") before it is shown:
// known schema version, the chain and wallet asked for, records strictly newest first and all below `before`, each
// record's key well formed, and a `next` cursor that does not move forward. History pages are shown, never stored.

import { EXPORT_SCHEMA_VERSION, type HistoryPage } from "@avana/services-common/export";

export class HistoryRejected extends Error {}

const ADDRESS = /^0x[0-9a-f]{40}$/;

export function validateHistoryPage(page: HistoryPage, chainId: number, wallet: string, before: bigint | null): void {
  if (page.schemaVersion !== EXPORT_SCHEMA_VERSION) throw new HistoryRejected(`schema version ${page.schemaVersion} is not ${EXPORT_SCHEMA_VERSION}`);
  if (page.chainId !== chainId) throw new HistoryRejected(`history is for chain ${page.chainId}`);
  if (page.wallet !== wallet.toLowerCase()) throw new HistoryRejected(`history is for wallet ${page.wallet}`);
  if (!page.proxies.every((p) => ADDRESS.test(p))) throw new HistoryRejected("a proxy is not a lower-case address");
  const upper = BigInt(page.before);
  if (before !== null && upper > before) throw new HistoryRejected(`history starts at ${upper}, above the requested ${before}`);
  let prev: [bigint, number] | null = null;
  for (const r of page.records) {
    const n = BigInt(r.blockNumber);
    if (n >= upper) throw new HistoryRejected(`record ${r.key} is not below ${upper}`);
    if (prev && (n > prev[0] || (n === prev[0] && r.logIndex >= prev[1]))) throw new HistoryRejected(`record ${r.key} out of order`);
    if (r.key !== `${chainId}:${r.txHash}:${r.logIndex}`) throw new HistoryRejected(`record key ${r.key} is malformed`);
    prev = [n, r.logIndex];
  }
  if (page.next !== null) {
    const next = BigInt(page.next.before);
    if (next > upper || (prev !== null && next < prev[0])) throw new HistoryRejected("next cursor is outside the page");
  }
}
