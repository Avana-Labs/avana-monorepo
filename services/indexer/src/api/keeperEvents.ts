// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The keeper stream (EXPORT.md, "Keeper stream"): the `event_log` rows of the kinds the keeper follows, at the
// chain head, after a cursor that names its block's hash. A cursor whose block left the canonical chain is refused
// with the finalized block, so the keeper rewinds with the indexer instead of keeping rows a reorg removed.

import { db, publicClients } from "ponder:api";
import schema from "ponder:schema";
import { and, asc, eq, gt, inArray, lte } from "ponder";
import {
  KEEPER_STREAM_KINDS,
  KEEPER_STREAM_VERSION,
  type ExportRecord,
  type HexString,
  type KeeperStreamPage,
  type KeeperStreamReorg,
  chainById,
} from "@avana/services-common";
import { type StreamRequest, closePage, cursorCanonical, streamableThrough } from "../lib/keeperStream.ts";

type Row = typeof schema.eventLog.$inferSelect;

function clientFor(chainId: number) {
  const client = publicClients[chainById(chainId).key];
  if (!client) throw new Error(`chain ${chainId} is not indexed`);
  return client;
}

async function rows(chainId: number, afterBlock: bigint, toBlock: bigint, limit: number): Promise<Row[]> {
  const t = schema.eventLog;
  return db
    .select()
    .from(t)
    .where(and(eq(t.chainId, chainId), gt(t.blockNumber, afterBlock), lte(t.blockNumber, toBlock), inArray(t.kind, [...KEEPER_STREAM_KINDS])))
    .orderBy(asc(t.blockNumber), asc(t.logIndex))
    .limit(limit);
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

/** A page, a reorg refusal, or null when no block after the cursor is indexed yet (the endpoint answers 204). */
export async function buildKeeperEvents(req: StreamRequest): Promise<KeeperStreamPage | KeeperStreamReorg | null> {
  const client = clientFor(req.chainId);
  const finalizedBlock = await client.getBlock({ blockTag: "finalized" });
  if (req.after) {
    const at = await client.getBlock({ blockNumber: req.after.block }).catch(() => null);
    if (!at || !cursorCanonical(req.after, at.hash)) {
      return { reorg: true, chainId: req.chainId, finalized: { block: finalizedBlock.number.toString(10), hash: finalizedBlock.hash as HexString } };
    }
  }
  const [progress] = await db.select().from(schema.chainProgress).where(eq(schema.chainProgress.chainId, req.chainId));
  const through = streamableThrough(progress ? progress.blockNumber : null);
  const afterBlock = req.after ? req.after.block : -1n;
  if (through <= afterBlock) return null;

  const raw = await rows(req.chainId, afterBlock, through, req.limit);
  const closed = closePage(raw, through, req.limit);
  const served = closed.wholeBlock === null ? closed.rows : await rows(req.chainId, closed.wholeBlock - 1n, closed.wholeBlock, Number.MAX_SAFE_INTEGER);
  const tip = await client.getBlock({ blockNumber: closed.toBlock });
  // A record above the finalized block whose hash is not the chain's hash at that height belongs to a branch the
  // indexer has not rolled back yet; the page is refused as a reorg so the keeper re-reads once the indexer replayed.
  const unfinal = new Map<bigint, string>();
  for (const r of served) if (r.blockNumber > finalizedBlock.number) unfinal.set(r.blockNumber, r.blockHash);
  for (const [n, hash] of unfinal) {
    const canonical = n === closed.toBlock ? tip.hash : (await client.getBlock({ blockNumber: n })).hash;
    if (!cursorCanonical({ block: n, hash }, canonical)) {
      return { reorg: true, chainId: req.chainId, finalized: { block: finalizedBlock.number.toString(10), hash: finalizedBlock.hash as HexString } };
    }
  }
  return {
    version: KEEPER_STREAM_VERSION,
    chainId: req.chainId,
    after: req.after ? { block: req.after.block.toString(10), hash: req.after.hash } : null,
    next: { block: closed.toBlock.toString(10), hash: tip.hash as HexString },
    fromBlock: (afterBlock + 1n).toString(10),
    toBlock: closed.toBlock.toString(10),
    records: served.map(toRecord),
    indexedBlock: through.toString(10),
    finalizedBlock: finalizedBlock.number.toString(10),
  };
}
