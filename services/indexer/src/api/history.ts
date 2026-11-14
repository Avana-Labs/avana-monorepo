// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The wallet history (EXPORT.md, "Older history"): the logs naming a wallet or one of its attributed proxies, newest
// first, read from `log_party` and served as export records up to the export's servable block, so a history page never
// holds a block a reorg can remove. Convex shows these records without storing them.

import { db } from "ponder:api";
import schema from "ponder:schema";
import { and, desc, eq, inArray, lt } from "ponder";
import { EXPORT_SCHEMA_VERSION, type HexString, type HistoryPage } from "@avana/services-common";
import { type HistoryRequest, closeHistoryPage } from "../lib/history.ts";
import { servableThrough, toRecord } from "./exportPage.ts";

/** The wallet's proxies attributed by both creation events (TEST-144); a one-sided account is never attributed. */
async function attributedProxies(chainId: number, wallet: HexString): Promise<HexString[]> {
  const t = schema.account;
  const rows = await db.select().from(t).where(and(eq(t.chainId, chainId), eq(t.wallet, wallet)));
  return [...new Set(rows.filter((r) => r.adapterSeen && r.managerSeen).map((r) => r.proxy.toLowerCase() as HexString))].sort();
}

/** The keys of the logs naming any party, below `before`, newest first; one key per log. */
async function keysBelow(chainId: number, parties: readonly HexString[], before: bigint, limit: number, onlyBlock: bigint | null) {
  const t = schema.logParty;
  const where = onlyBlock === null ? lt(t.blockNumber, before) : eq(t.blockNumber, onlyBlock);
  const rows = await db
    .select({ txHash: t.txHash, logIndex: t.logIndex, blockNumber: t.blockNumber })
    .from(t)
    .where(and(eq(t.chainId, chainId), inArray(t.party, [...parties]), where))
    .orderBy(desc(t.blockNumber), desc(t.logIndex))
    // A log naming several parties appears once per party; read enough to fill the page with distinct logs.
    .limit(onlyBlock === null ? limit * parties.length : Number.MAX_SAFE_INTEGER);
  const seen = new Set<string>();
  const out: typeof rows = [];
  for (const r of rows) {
    const key = `${r.txHash}:${r.logIndex}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(r);
  }
  return onlyBlock === null ? out.slice(0, limit) : out;
}

export async function buildHistoryPage(req: HistoryRequest): Promise<HistoryPage> {
  const { through } = await servableThrough(req.chainId);
  const cap = through + 1n;
  const before = req.before === null || req.before > cap ? cap : req.before;
  const proxies = await attributedProxies(req.chainId, req.wallet);
  const parties = [req.wallet, ...proxies];

  let keys = await keysBelow(req.chainId, parties, before, req.limit, null);
  const closed = closeHistoryPage(keys, req.limit);
  keys = closed.wholeBlock === null ? closed.rows : await keysBelow(req.chainId, parties, before, req.limit, closed.wholeBlock);

  const t = schema.eventLog;
  const rows = keys.length === 0
    ? []
    : await db
        .select()
        .from(t)
        .where(and(eq(t.chainId, req.chainId), inArray(t.txHash, [...new Set(keys.map((k) => k.txHash))])))
        .orderBy(desc(t.blockNumber), desc(t.logIndex));
  const wanted = new Set(keys.map((k) => `${k.txHash}:${k.logIndex}`));
  const records = rows.filter((r) => wanted.has(`${r.txHash}:${r.logIndex}`)).map(toRecord);

  return {
    schemaVersion: EXPORT_SCHEMA_VERSION,
    chainId: req.chainId,
    wallet: req.wallet,
    proxies,
    before: before.toString(10),
    records,
    next: closed.next === null ? null : { before: closed.next.toString(10) },
  };
}
