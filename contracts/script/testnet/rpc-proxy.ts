// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One test network's RPC for the test-network app (app.ts): every service, and the webapp in the browser, reads the
// network through this local proxy (http://127.0.0.1:<port>), so the network's RPC URL, which carries the provider's
// key, is held by this process alone. The URL reaches it in its environment (PROXY_UPSTREAMS, comma-separated for
// several endpoints), never on a command line, and no line it writes names it.
// - JSON-RPC over HTTP is forwarded, retried with backoff on a rate limit or a failure, rotating through the endpoints.
// - A WebSocket upgrade (the indexer's and the keeper's new-head subscriptions) is tunnelled to the endpoint's
//   WebSocket (https becomes wss, http ws; PROXY_WS_UPSTREAM when the provider's differs), bytes passed as they are.
// - Browser requests are answered with CORS headers for PROXY_CORS_ORIGINS only (the webapp's origins).
// - GET answers the proxy's counts.
//
// Usage (started by app.ts): PROXY_UPSTREAMS=<urls> node script/testnet/rpc-proxy.ts <port>

import { type IncomingHttpHeaders, createServer } from "node:http";
import { connect as netConnect } from "node:net";
import type { Duplex } from "node:stream";
import { connect as tlsConnect } from "node:tls";

/** The WebSocket endpoint of an HTTP endpoint: the same host and path, https→wss and http→ws. */
export function wsUpstreamOf(httpUrl: string): URL {
  const u = new URL(httpUrl);
  if (u.protocol === "https:" || u.protocol === "wss:") u.protocol = "wss:";
  else if (u.protocol === "http:" || u.protocol === "ws:") u.protocol = "ws:";
  else throw new Error("an RPC endpoint must be http(s) or ws(s)");
  return u;
}

const HOP = new Set(["host", "origin", "connection", "upgrade", "content-length", "transfer-encoding", "proxy-connection", "keep-alive"]);

/** The upgrade request sent to the upstream: its path and host, the client's WebSocket headers (key, version,
 * extensions, protocol) and nothing that names the client's origin. */
export function upgradeRequest(upstream: URL, headers: IncomingHttpHeaders): string {
  const lines = [`GET ${upstream.pathname || "/"}${upstream.search} HTTP/1.1`, `Host: ${upstream.host}`, "Connection: Upgrade", "Upgrade: websocket"];
  for (const [k, v] of Object.entries(headers)) {
    if (HOP.has(k.toLowerCase()) || v === undefined) continue;
    for (const one of Array.isArray(v) ? v : [v]) lines.push(`${k}: ${one}`);
  }
  return `${lines.join("\r\n")}\r\n\r\n`;
}

/** CORS response headers for a browser request from `origin`: only an allowed origin is named. */
export function corsHeaders(origin: string | undefined, allowed: readonly string[]): Record<string, string> {
  if (!origin || !allowed.includes(origin)) return {};
  return { "access-control-allow-origin": origin, "access-control-allow-methods": "POST, OPTIONS", "access-control-allow-headers": "content-type", vary: "origin" };
}

/** Whether an upstream answer is to be retried on another attempt (rate limit, server error). */
export const retryable = (status: number, text: string) => status === 429 || status >= 500 || /rate limit|too many requests/i.test(text.slice(0, 300));

function main(): void {
  const port = Number(process.argv[2]);
  const upstreams = (process.env.PROXY_UPSTREAMS ?? "").split(",").map((u) => u.trim()).filter(Boolean);
  const origins = (process.env.PROXY_CORS_ORIGINS ?? "").split(",").map((o) => o.trim()).filter(Boolean);
  if (!port || upstreams.length === 0) {
    process.stderr.write("usage: PROXY_UPSTREAMS=<urls> node rpc-proxy.ts <port>\n");
    process.exit(2);
  }
  const wsUpstream = wsUpstreamOf(process.env.PROXY_WS_UPSTREAM?.trim() || upstreams[0]!);
  const stats = { forwarded: 0, retried: 0, failed: 0, sockets: 0, socketErrors: 0 };
  let next = 0;

  async function forward(body: string): Promise<{ status: number; text: string }> {
    let wait = 500;
    for (let attempt = 0; attempt < 8; attempt++) {
      const url = upstreams[next++ % upstreams.length]!;
      try {
        const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body, signal: AbortSignal.timeout(60_000) });
        const text = await r.text();
        if (retryable(r.status, text)) throw new Error("retry");
        stats.forwarded++;
        return { status: r.status, text };
      } catch {
        // The error names the endpoint: it is counted, never written.
        stats.retried++;
        await new Promise((res) => setTimeout(res, wait));
        wait = Math.min(wait * 2, 15_000);
      }
    }
    stats.failed++;
    return { status: 502, text: JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32000, message: "test-network RPC unavailable after retries" } }) };
  }

  const server = createServer((req, res) => {
    const cors = corsHeaders(req.headers.origin, origins);
    if (req.method === "OPTIONS") {
      res.writeHead(Object.keys(cors).length ? 204 : 403, cors).end();
      return;
    }
    if (req.method !== "POST") {
      res.writeHead(200, { "content-type": "application/json", ...cors }).end(JSON.stringify(stats));
      return;
    }
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", async () => {
      const r = await forward(body);
      res.writeHead(r.status, { "content-type": "application/json", ...cors }).end(r.text);
    });
  });

  server.on("upgrade", (req, client: Duplex, head: Buffer) => {
    stats.sockets++;
    const secure = wsUpstream.protocol === "wss:";
    const port = Number(wsUpstream.port || (secure ? 443 : 80));
    const upstream = secure ? tlsConnect({ host: wsUpstream.hostname, port, servername: wsUpstream.hostname }) : netConnect({ host: wsUpstream.hostname, port });
    const fail = () => {
      stats.socketErrors++;
      client.destroy();
      upstream.destroy();
    };
    upstream.once(secure ? "secureConnect" : "connect", () => {
      upstream.write(upgradeRequest(wsUpstream, req.headers));
      if (head.length) upstream.write(head);
      upstream.pipe(client);
      client.pipe(upstream);
    });
    upstream.on("error", fail);
    client.on("error", fail);
    upstream.on("close", () => client.destroy());
    client.on("close", () => upstream.destroy());
  });

  server.listen(port, "127.0.0.1", () => process.stdout.write(`rpc proxy on 127.0.0.1:${port}, ${upstreams.length} endpoint(s)\n`));
}

if (process.argv[1]?.endsWith("rpc-proxy.ts")) main();
