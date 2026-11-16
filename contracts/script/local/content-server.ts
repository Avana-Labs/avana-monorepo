// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Serves the listing metadata files of every local chain (deployments-local/<network>/listing-content/<salt>.json) at
// LISTING_CONTENT_URL/<salt>.json, where Convex fetches them after each listing operation runs (services/convex
// README, Listing metadata). A name not found in any chain's directory is a 404.
//
// Usage: node script/local/content-server.ts <port>

import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { basename, join } from "node:path";
import { CHAINS, outDir } from "./lib/env.ts";

const port = Number(process.argv[2] ?? 8788);
createServer(async (req, res) => {
  const name = basename(req.url ?? "");
  if (!/^0x[0-9a-fA-F]{64}\.json$/.test(name)) {
    res.writeHead(404).end();
    return;
  }
  for (const c of CHAINS) {
    try {
      const body = await readFile(join(outDir(c), "listing-content", name));
      res.writeHead(200, { "content-type": "application/json" }).end(body);
      return;
    } catch {}
  }
  res.writeHead(404).end();
}).listen(port, "127.0.0.1", () => process.stdout.write(`listing content on http://127.0.0.1:${port}\n`));
