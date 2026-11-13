// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Checks an export page before it is applied (README, "Scheduled pull", step 4): known schema version, the range
// starts right after the checkpoint, ends at or below finality, records in order and inside the range, every
// record's block hash equal to the page's entry for its block, and the page hash recomputed from canonical JSON.
// The hash of `toBlock` is compared with Convex's own RPC by the caller.

import { keccak256, toBytes } from "viem";
import { EXPORT_SCHEMA_VERSION, type ExportPage, canonicalJson } from "@avana/services-common/export";
import { SERIES_SCHEMA_VERSION, type SeriesExportPage } from "@avana/services-common/series";

export class PageRejected extends Error {}

export function validatePage(page: ExportPage, chainId: number, throughBlock: bigint | null): void {
  if (page.schemaVersion !== EXPORT_SCHEMA_VERSION) throw new PageRejected(`schema version ${page.schemaVersion} is not ${EXPORT_SCHEMA_VERSION}`);
  if (page.chainId !== chainId) throw new PageRejected(`page is for chain ${page.chainId}`);
  const from = BigInt(page.fromBlock);
  const to = BigInt(page.toBlock);
  const expectedFrom = throughBlock === null ? 0n : throughBlock + 1n;
  if (from !== expectedFrom) throw new PageRejected(`page starts at ${from}, the checkpoint expects ${expectedFrom}`);
  if (to < from) throw new PageRejected("page ends before it starts");
  if (to > BigInt(page.finalizedBlock)) throw new PageRejected("page passes the finalized block");
  if (BigInt(page.next.throughBlock) !== to) throw new PageRejected("cursor does not end at toBlock");
  const hashes = new Map(page.blocks.map((b) => [b.number, b.hash]));
  if (hashes.get(page.toBlock) !== page.toBlockHash) throw new PageRejected("toBlock hash differs from its block entry");
  let prev: [bigint, number] | null = null;
  for (const r of page.records) {
    const n = BigInt(r.blockNumber);
    if (n < from || n > to) throw new PageRejected(`record ${r.key} outside the page`);
    if (prev && (n < prev[0] || (n === prev[0] && r.logIndex <= prev[1]))) throw new PageRejected(`record ${r.key} out of order`);
    if (hashes.get(r.blockNumber) !== r.blockHash) throw new PageRejected(`record ${r.key} has another hash for block ${r.blockNumber}`);
    if (r.key !== `${chainId}:${r.txHash}:${r.logIndex}`) throw new PageRejected(`record key ${r.key} is malformed`);
    prev = [n, r.logIndex];
  }
  const { pageHash, ...body } = page;
  if (keccak256(toBytes(canonicalJson(body))) !== pageHash) throw new PageRejected("page hash does not match its content");
}

export function validateSeriesPage(page: SeriesExportPage, chainId: number, throughTime: number): void {
  if (page.schemaVersion !== SERIES_SCHEMA_VERSION) throw new PageRejected(`series schema version ${page.schemaVersion} is not ${SERIES_SCHEMA_VERSION}`);
  if (page.chainId !== chainId) throw new PageRejected(`series page is for chain ${page.chainId}`);
  const after = page.after?.throughTime ?? -1;
  if (after !== throughTime) throw new PageRejected(`series page starts after ${after}, the checkpoint is ${throughTime}`);
  if (page.next.throughTime <= after) throw new PageRejected("series cursor does not advance");
  for (const r of page.records) if (r.chainId !== chainId) throw new PageRejected("series record of another chain");
  const { pageHash, ...body } = page;
  if (keccak256(toBytes(canonicalJson(body))) !== pageHash) throw new PageRejected("series page hash does not match its content");
}

/** Block timestamps of a page in milliseconds, for the `at` of each record. */
export function blockTimes(page: ExportPage): Map<string, number> {
  return new Map(page.blocks.map((b) => [b.number, Number(b.timestamp) * 1000]));
}
