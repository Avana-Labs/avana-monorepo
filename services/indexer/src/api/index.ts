// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The indexer's only HTTP surface besides Ponder's /health and /ready: the authenticated export. No GraphQL or
// SQL endpoint is mounted; the frontend never queries the indexer (services/README.md).

import { Hono } from "hono";
import { EXPORT_MAX_RECORDS } from "@avana/services-common";
import { requireExportAuth } from "./auth.ts";
import { buildExportPage } from "./exportPage.ts";

const app = new Hono();

app.use("/export/*", requireExportAuth());

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

export default app;
