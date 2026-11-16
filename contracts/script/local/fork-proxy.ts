// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The fork's upstream for one chain: anvil forks from this local proxy (http://127.0.0.1:<port>), which forwards each
// JSON-RPC request to the network's RPC endpoints. The endpoints reach it in its environment (FORK_UPSTREAMS,
// comma-separated), so no RPC URL appears on any command line or in the repository. A rate-limited or failed request
// is retried with exponential backoff, rotating through the endpoints.
//
// Usage (started by the stack): FORK_UPSTREAMS=<urls> node script/local/fork-proxy.ts <port>

import { createServer } from "node:http";

const port = Number(process.argv[2]);
const upstreams = (process.env.FORK_UPSTREAMS ?? "").split(",").map((u) => u.trim()).filter(Boolean);
if (!port || upstreams.length === 0) {
  process.stderr.write("usage: FORK_UPSTREAMS=<urls> node fork-proxy.ts <port>\n");
  process.exit(2);
}
const stats = { forwarded: 0, retried: 0, failed: 0 };
let next = 0;

async function forward(body: string): Promise<{ status: number; text: string }> {
  let wait = 500;
  for (let attempt = 0; attempt < 8; attempt++) {
    const url = upstreams[next++ % upstreams.length]!;
    try {
      const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body, signal: AbortSignal.timeout(60_000) });
      const text = await r.text();
      if (r.status === 429 || r.status >= 500 || /rate limit|too many requests/i.test(text.slice(0, 300))) throw new Error(`HTTP ${r.status}`);
      stats.forwarded++;
      return { status: r.status, text };
    } catch {
      stats.retried++;
      await new Promise((res) => setTimeout(res, wait));
      wait = Math.min(wait * 2, 15_000);
    }
  }
  stats.failed++;
  return { status: 502, text: JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32000, message: "fork upstream unavailable after retries" } }) };
}

createServer((req, res) => {
  if (req.method !== "POST") {
    res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(stats));
    return;
  }
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", async () => {
    const r = await forward(body);
    res.writeHead(r.status, { "content-type": "application/json" }).end(r.text);
  });
}).listen(port, "127.0.0.1", () => process.stdout.write(`fork proxy on 127.0.0.1:${port}, ${upstreams.length} upstream(s)\n`));
