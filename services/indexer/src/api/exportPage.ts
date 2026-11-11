// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Builds one export page (EXPORT.md): records strictly after the cursor, up to the chain's finalized block and
// the indexer's own progress, closed at a block boundary, with the hash of every block it covers.

import { db, publicClients } from "ponder:api";
import schema from "ponder:schema";
import { and, asc, eq, gte, lte } from "ponder";
import { keccak256, toBytes } from "viem";
import {
  EXPORT_MAX_RECORDS,
  EXPORT_SCHEMA_VERSION,
  type ExportBlock,
  type ExportCursor,
  type ExportPage,
  type ExportRecord,
  type HexString,
  chainById,
} from "@avana/services-common";

type Row = typeof schema.eventLog.$inferSelect;

/** Highest block the export may serve: finalized on the chain and fully handled by the indexer. */
async function servableThrough(chainId: number): Promise<{ through: bigint; finalized: bigint }> {
  const client = publicClients[chainById(chainId).key as keyof typeof publicClients];
  const finalized = (await client.getBlock({ blockTag: "finalized" })).number;
  const [progress] = await db.select().from(schema.chainProgress).where(eq(schema.chainProgress.chainId, chainId));
  // The Progress row of block N may be written before N's logs are handled, so N itself is not served.
  const indexed = progress ? progress.blockNumber - 1n : -1n;
  return { through: finalized < indexed ? finalized : indexed, finalized };
}

async function rowsIn(chainId: number, fromBlock: bigint, toBlock: bigint, limit: number): Promise<Row[]> {
  const t = schema.eventLog;
  return db
    .select()
    .from(t)
    .where(and(eq(t.chainId, chainId), gte(t.blockNumber, fromBlock), lte(t.blockNumber, toBlock)))
    .orderBy(asc(t.blockNumber), asc(t.logIndex))
    .limit(limit);
}

/** A page never splits a block: a full page drops its last block unless that block is the whole page. */
async function closeAtBlock(chainId: number, rows: Row[], through: bigint, limit: number) {
  if (rows.length < limit) return { rows, toBlock: through };
  const last = rows[rows.length - 1]!.blockNumber;
  const complete = rows.filter((r) => r.blockNumber < last);
  if (complete.length > 0) return { rows: complete, toBlock: last - 1n };
  return { rows: await rowsIn(chainId, last, last, Number.MAX_SAFE_INTEGER), toBlock: last };
}

function toRecord(r: Row): ExportRecord {
  return {
    key: `${r.chainId}:${r.txHash}:${r.logIndex}`,
    kind: r.kind,
    blockNumber: r.blockNumber.toString(10),
    blockHash: r.blockHash,
    txHash: r.txHash,
    logIndex: r.logIndex,
    address: r.address,
    args: r.args as Record<string, unknown>,
  };
}

/** Returns null when no block after the cursor is final and indexed yet (the endpoint answers 204). */
export async function buildExportPage(chainId: number, after: ExportCursor | null, limit = EXPORT_MAX_RECORDS): Promise<ExportPage | null> {
  const { through, finalized } = await servableThrough(chainId);
  const fromBlock = after ? BigInt(after.throughBlock) + 1n : 0n;
  if (through < fromBlock) return null;
  const raw = await rowsIn(chainId, fromBlock, through, limit);
  const { rows, toBlock } = await closeAtBlock(chainId, raw, through, limit);
  const client = publicClients[chainById(chainId).key as keyof typeof publicClients];
  const tip = await client.getBlock({ blockNumber: toBlock });
  const blocks = new Map<string, ExportBlock>();
  for (const r of rows) {
    blocks.set(r.blockNumber.toString(10), { number: r.blockNumber.toString(10), hash: r.blockHash, timestamp: r.blockTimestamp.toString(10) });
  }
  blocks.set(toBlock.toString(10), { number: toBlock.toString(10), hash: tip.hash as HexString, timestamp: tip.timestamp.toString(10) });
  const body = {
    schemaVersion: EXPORT_SCHEMA_VERSION,
    chainId,
    after,
    next: { throughBlock: toBlock.toString(10) },
    fromBlock: fromBlock.toString(10),
    toBlock: toBlock.toString(10),
    toBlockHash: tip.hash as HexString,
    blocks: [...blocks.values()],
    records: rows.map(toRecord),
    finalizedBlock: finalized.toString(10),
  };
  return { ...body, pageHash: keccak256(toBytes(canonicalJson(body))) };
}

/** JSON with object keys sorted at every level, so producer and consumer hash the same bytes. */
export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}
