// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The indexer's only HTTP surface besides Ponder's /health and /ready: the authenticated export for Convex and the
// authenticated keeper stream. No GraphQL or SQL endpoint is mounted; the frontend never queries the indexer
// (services/README.md).

import { Hono } from "hono";
import { EXPORT_MAX_RECORDS } from "@avana/services-common";
import { requireExportAuth } from "./auth.ts";
import { buildExportPage } from "./exportPage.ts";
import { buildKeeperEvents } from "./keeperEvents.ts";
import { parseStreamRequest } from "../lib/keeperStream.ts";
import { POOL_HISTORY_MAX_BLOCKS, PoolHistoryRefused, readPoolHistory } from "./poolHistory.ts";
import { SERIES_MAX_RECORDS, buildSeriesPage } from "./seriesPage.ts";

const app = new Hono();

// One key list for both consumers; each consumer has its own key ID, so either can be rotated or revoked alone.
const auth = requireExportAuth();
app.use("/export/*", auth);
app.use("/keeper/*", auth);

/**
 * GET /keeper/v1/events?chainId=1&after=<block>&afterHash=<hash>&limit=<n>
 * 200 with a KeeperStreamPage; 204 when no block after the cursor is indexed yet; 409 with KeeperStreamReorg when the
 * cursor's block is no longer canonical; 400 on a malformed parameter.
 */
app.get("/keeper/v1/events", async (c) => {
  const req = parseStreamRequest({ chainId: c.req.query("chainId"), after: c.req.query("after"), afterHash: c.req.query("afterHash"), limit: c.req.query("limit") });
  if ("error" in req) return c.json({ error: req.error }, 400);
  const page = await buildKeeperEvents(req);
  if (page === null) return c.body(null, 204);
  if ("reorg" in page) return c.json(page, 409);
  return c.json(page);
});

/**
 * GET /export/v1/pages?chainId=1&after=<throughBlock>&limit=<n>
 * 200 with an ExportPage; 204 when no new block is final and indexed; 400 on a malformed parameter.
 */
app.get("/export/v1/pages", async (c) => {
  const chainId = c.req.query("chainId") ?? "";
  const after = c.req.query("after");
  const limit = c.req.query("limit") ?? String(EXPORT_MAX_RECORDS);
  if (!/^\d+$/.test(chainId) || (after !== undefined && !/^\d+$/.test(after)) || !/^\d+$/.test(limit)) {
    return c.json({ error: "chainId, after and limit are decimal integers" }, 400);
  }
  const n = Number(limit);
  if (n < 1 || n > EXPORT_MAX_RECORDS) return c.json({ error: `limit must be 1..${EXPORT_MAX_RECORDS}` }, 400);
  const page = await buildExportPage(Number(chainId), after === undefined ? null : { throughBlock: after }, n);
  if (page === null) return c.body(null, 204);
  return c.json(page);
});

/**
 * GET /export/v1/series?chainId=1&after=<throughTime>&limit=<n>
 * 200 with a SeriesExportPage of closed buckets; 204 when no bucket closed after the cursor; 400 on a bad parameter.
 */
app.get("/export/v1/series", async (c) => {
  const chainId = c.req.query("chainId") ?? "";
  const after = c.req.query("after");
  const limit = c.req.query("limit") ?? String(SERIES_MAX_RECORDS);
  if (!/^\d+$/.test(chainId) || (after !== undefined && !/^\d+$/.test(after)) || !/^\d+$/.test(limit)) {
    return c.json({ error: "chainId, after and limit are decimal integers" }, 400);
  }
  const n = Number(limit);
  if (n < 1 || n > SERIES_MAX_RECORDS) return c.json({ error: `limit must be 1..${SERIES_MAX_RECORDS}` }, 400);
  const page = await buildSeriesPage(Number(chainId), after === undefined ? null : Number(after), n);
  if (page === null) return c.body(null, 204);
  return c.json(page);
});

/**
 * GET /export/v1/pool-history?chainId=1&pool=0x…&fromBlock=<n>&toBlock=<n>
 * 200 with the pool's hourly and daily buckets of a finalized range before its listing block; 400 otherwise.
 */
app.get("/export/v1/pool-history", async (c) => {
  const chainId = c.req.query("chainId") ?? "";
  const pool = (c.req.query("pool") ?? "").toLowerCase();
  const fromBlock = c.req.query("fromBlock") ?? "";
  const toBlock = c.req.query("toBlock") ?? "";
  if (!/^\d+$/.test(chainId) || !/^0x[0-9a-f]{40}$/.test(pool) || !/^\d+$/.test(fromBlock) || !/^\d+$/.test(toBlock)) {
    return c.json({ error: `chainId, fromBlock and toBlock are decimal integers, pool an address; at most ${POOL_HISTORY_MAX_BLOCKS} blocks` }, 400);
  }
  try {
    return c.json(await readPoolHistory(Number(chainId), pool as `0x${string}`, BigInt(fromBlock), BigInt(toBlock)));
  } catch (e) {
    if (e instanceof PoolHistoryRefused) return c.json({ error: e.message }, 400);
    throw e;
  }
});

export default app;
