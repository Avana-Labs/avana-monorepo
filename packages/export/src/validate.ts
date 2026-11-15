// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The checks a consumer runs on every export response before it uses it (services/indexer/EXPORT.md). Event pages:
// known version, the range continues the cursor and stays within finality, records ordered and inside the range,
// each record's block hash equal to the page's entry for its block, well-formed keys and the page hash recomputed
// from canonical JSON. The caller still compares `toBlockHash` with its own RPC. Series, history, pool-history and
// premium-refresh responses get the checks their sections of EXPORT.md describe.

import { keccak256, toBytes } from "viem";
import { EXPORT_SCHEMA_VERSION, type ExportPage, type HexString, type HistoryPage, type PremiumRefreshList, canonicalJson } from "@avana/services-common/export";
import { SERIES_SCHEMA_VERSION, type SeriesExportPage, type SeriesRecord } from "@avana/services-common/series";

export class PageRejected extends Error {
  override readonly name = "PageRejected";
}

const ADDRESS = /^0x[0-9a-f]{40}$/;
const DECIMAL = /^\d+$/;

/** keccak256 of the canonical JSON of a page body (every field but `pageHash`): the hash the producer writes. */
export function pageHashOf(page: object): HexString {
  const { pageHash: _drop, ...body } = page as { pageHash?: unknown };
  return keccak256(toBytes(canonicalJson(body)));
}

/** Adds `pageHash` to a page body, as the indexer does when it serves a page. */
export function withPageHash<B extends object>(body: B): B & { readonly pageHash: HexString } {
  return { ...body, pageHash: pageHashOf(body) };
}

function decimal(value: string, what: string): bigint {
  if (!DECIMAL.test(value)) throw new PageRejected(`${what} is not a decimal integer`);
  return BigInt(value);
}

/** `throughBlock` is the consumer's checkpoint; null before the first page. */
export function validatePage(page: ExportPage, chainId: number, throughBlock: bigint | null): void {
  if (page.schemaVersion !== EXPORT_SCHEMA_VERSION) throw new PageRejected(`schema version ${page.schemaVersion} is not ${EXPORT_SCHEMA_VERSION}`);
  if (page.chainId !== chainId) throw new PageRejected(`page is for chain ${page.chainId}`);
  const after = page.after === null ? null : decimal(page.after.throughBlock, "after");
  if (after !== throughBlock) throw new PageRejected(`page continues ${after ?? "the start"}, the checkpoint is ${throughBlock ?? "the start"}`);
  const from = decimal(page.fromBlock, "fromBlock");
  const to = decimal(page.toBlock, "toBlock");
  const expectedFrom = throughBlock === null ? 0n : throughBlock + 1n;
  if (from !== expectedFrom) throw new PageRejected(`page starts at ${from}, the checkpoint expects ${expectedFrom}`);
  if (to < from) throw new PageRejected("page ends before it starts");
  if (to > decimal(page.finalizedBlock, "finalizedBlock")) throw new PageRejected("page passes the finalized block");
  if (decimal(page.next.throughBlock, "next") !== to) throw new PageRejected("cursor does not end at toBlock");
  const hashes = new Map(page.blocks.map((b) => [b.number, b.hash]));
  if (hashes.get(page.toBlock) !== page.toBlockHash) throw new PageRejected("toBlock hash differs from its block entry");
  let prev: [bigint, number] | null = null;
  for (const r of page.records) {
    const n = decimal(r.blockNumber, `record ${r.key} block`);
    if (n < from || n > to) throw new PageRejected(`record ${r.key} outside the page`);
    if (prev && (n < prev[0] || (n === prev[0] && r.logIndex <= prev[1]))) throw new PageRejected(`record ${r.key} out of order`);
    if (hashes.get(r.blockNumber) !== r.blockHash) throw new PageRejected(`record ${r.key} has another hash for block ${r.blockNumber}`);
    if (r.key !== `${chainId}:${r.txHash}:${r.logIndex}`) throw new PageRejected(`record key ${r.key} is malformed`);
    prev = [n, r.logIndex];
  }
  if (pageHashOf(page) !== page.pageHash) throw new PageRejected("page hash does not match its content");
}

/** `throughTime` is the consumer's series cursor; -1 before the first page. */
export function validateSeriesPage(page: SeriesExportPage, chainId: number, throughTime: number): void {
  if (page.schemaVersion !== SERIES_SCHEMA_VERSION) throw new PageRejected(`series schema version ${page.schemaVersion} is not ${SERIES_SCHEMA_VERSION}`);
  if (page.chainId !== chainId) throw new PageRejected(`series page is for chain ${page.chainId}`);
  const after = page.after?.throughTime ?? -1;
  if (after !== throughTime) throw new PageRejected(`series page starts after ${after}, the checkpoint is ${throughTime}`);
  if (page.next.throughTime <= after) throw new PageRejected("series cursor does not advance");
  for (const r of page.records) if (r.chainId !== chainId) throw new PageRejected("series record of another chain");
  if (pageHashOf(page) !== page.pageHash) throw new PageRejected("series page hash does not match its content");
}

/** `before` is the exclusive upper block the request named; null for the newest page. */
export function validateHistoryPage(page: HistoryPage, chainId: number, wallet: string, before: bigint | null): void {
  if (page.schemaVersion !== EXPORT_SCHEMA_VERSION) throw new PageRejected(`schema version ${page.schemaVersion} is not ${EXPORT_SCHEMA_VERSION}`);
  if (page.chainId !== chainId) throw new PageRejected(`history is for chain ${page.chainId}`);
  if (page.wallet !== wallet.toLowerCase()) throw new PageRejected(`history is for wallet ${page.wallet}`);
  if (!page.proxies.every((p) => ADDRESS.test(p))) throw new PageRejected("a proxy is not a lower-case address");
  const upper = decimal(page.before, "before");
  if (before !== null && upper > before) throw new PageRejected(`history starts at ${upper}, above the requested ${before}`);
  let prev: [bigint, number] | null = null;
  for (const r of page.records) {
    const n = decimal(r.blockNumber, `record ${r.key} block`);
    if (n >= upper) throw new PageRejected(`record ${r.key} is not below ${upper}`);
    if (prev && (n > prev[0] || (n === prev[0] && r.logIndex >= prev[1]))) throw new PageRejected(`record ${r.key} out of order`);
    if (r.key !== `${chainId}:${r.txHash}:${r.logIndex}`) throw new PageRejected(`record key ${r.key} is malformed`);
    prev = [n, r.logIndex];
  }
  if (page.next !== null) {
    const next = decimal(page.next.before, "next");
    if (next > upper || (prev !== null && next < prev[0])) throw new PageRejected("next cursor is outside the page");
  }
}

/** `/export/v1/pool-history`: the hourly and daily buckets of one pool over one block range. */
export interface PoolHistoryPage {
  readonly chainId: number;
  readonly pool: HexString;
  readonly fromBlock: string;
  readonly toBlock: string;
  readonly feePips: number;
  readonly records: readonly SeriesRecord[];
}

export function validatePoolHistory(page: PoolHistoryPage, chainId: number, pool: string, fromBlock: bigint, toBlock: bigint): void {
  if (page.chainId !== chainId) throw new PageRejected(`pool history is for chain ${page.chainId}`);
  if (page.pool !== pool.toLowerCase()) throw new PageRejected(`pool history is for pool ${page.pool}`);
  if (decimal(page.fromBlock, "fromBlock") !== fromBlock || decimal(page.toBlock, "toBlock") !== toBlock) throw new PageRejected("pool history covers another range");
  for (const r of page.records) {
    if (r.chainId !== chainId) throw new PageRejected("pool history record of another chain");
    if (decimal(r.blockNumber, "record block") > toBlock) throw new PageRejected("pool history record above the range");
  }
}

export function validatePremiumRefresh(list: PremiumRefreshList, chainId: number, spoke: string): void {
  if (list.chainId !== chainId) throw new PageRejected(`premium refresh is for chain ${list.chainId}`);
  if (list.spoke !== spoke.toLowerCase()) throw new PageRejected(`premium refresh is for Spoke ${list.spoke}`);
  decimal(list.asOfBlock, "asOfBlock");
  if (list.riskChangedBlock === null && list.proxies.length > 0) throw new PageRejected("proxies listed without a risk change");
  for (let i = 0; i < list.proxies.length; i++) {
    const p = list.proxies[i]!;
    if (!ADDRESS.test(p)) throw new PageRejected("a proxy is not a lower-case address");
    if (i > 0 && p <= list.proxies[i - 1]!) throw new PageRejected("proxies are not sorted and unique");
  }
}
