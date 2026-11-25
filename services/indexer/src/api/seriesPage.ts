// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The series export (EXPORT.md, "Series"): closed buckets only, ordered by bucket end, up to the time of the chain's
// finalized block and of the indexer's own progress. A bucket is closed once its end has passed, so every log and
// sample it holds is final and the row never changes after it is served.

import { db, publicClients } from "ponder:api";
import schema from "ponder:schema";
import { and, asc, eq, gt, lte } from "ponder";
import { keccak256, toBytes } from "viem";
import {
  type DecimalString,
  type Resolution,
  SERIES_SCHEMA_VERSION,
  canonicalJson,
  type SeriesExportPage,
  type SeriesRecord,
  type SeriesScopeKind,
  chainById,
} from "@avana/services-common";

type Row = typeof schema.seriesPoint.$inferSelect;

export const SERIES_MAX_RECORDS = 2_000;

async function servableThroughTime(chainId: number): Promise<{ throughTime: number; finalized: bigint }> {
  const client = publicClients[chainById(chainId).key];
  if (!client) throw new Error(`chain ${chainId} is not indexed`);
  const finalized = await client.getBlock({ blockTag: "finalized" });
  const [progress] = await db.select().from(schema.chainProgress).where(eq(schema.chainProgress.chainId, chainId));
  const indexedTime = progress ? Number(progress.blockTimestamp) - 1 : -1;
  return { throughTime: Math.min(Number(finalized.timestamp), indexedTime), finalized: finalized.number };
}

async function rowsAfter(chainId: number, after: number, through: number, limit: number): Promise<Row[]> {
  const t = schema.seriesPoint;
  return db
    .select()
    .from(t)
    .where(and(eq(t.chainId, chainId), gt(t.bucketEnd, after), lte(t.bucketEnd, through)))
    .orderBy(asc(t.bucketEnd), asc(t.scopeKind), asc(t.scopeKey), asc(t.resolution))
    .limit(limit);
}

function toRecord(r: Row): SeriesRecord {
  return {
    chainId: r.chainId,
    scopeKind: r.scopeKind as SeriesScopeKind,
    scopeKey: r.scopeKey,
    resolution: r.resolution as Resolution,
    bucketStart: r.bucketStart,
    blockNumber: r.blockNumber.toString(10),
    values: r.values as Record<string, DecimalString>,
  };
}

/** Null when no bucket closed after the cursor yet (the endpoint answers 204). */
export async function buildSeriesPage(chainId: number, after: number | null, limit = SERIES_MAX_RECORDS): Promise<SeriesExportPage | null> {
  const { throughTime, finalized } = await servableThroughTime(chainId);
  const from = after ?? -1;
  if (throughTime <= from) return null;
  let rows = await rowsAfter(chainId, from, throughTime, limit);
  let next = throughTime;
  if (rows.length === limit) {
    // A full page never splits one bucket end: drop the last end unless it is the whole page.
    const lastEnd = rows[rows.length - 1]!.bucketEnd;
    const complete = rows.filter((r) => r.bucketEnd < lastEnd);
    if (complete.length > 0) {
      rows = complete;
      next = lastEnd - 1;
    } else {
      rows = await rowsAfter(chainId, lastEnd - 1, lastEnd, Number.MAX_SAFE_INTEGER);
      next = lastEnd;
    }
  }
  if (rows.length === 0 && next <= from) return null;
  const body = {
    schemaVersion: SERIES_SCHEMA_VERSION,
    chainId,
    after: after === null ? null : { throughTime: after },
    next: { throughTime: next },
    records: rows.map(toRecord),
    finalizedBlock: finalized.toString(10),
  };
  return { ...body, pageHash: keccak256(toBytes(canonicalJson(body))) };
}
