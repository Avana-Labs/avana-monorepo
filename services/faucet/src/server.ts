// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The faucet's HTTP endpoint, on 127.0.0.1 only. Bodies are capped at 4 KiB.
//
//   POST /v1/grant                    { "chain": "ethereum" | "base", "wallet": "0x…" }  → the grant and its steps
//   GET  /v1/grant?chain=…&wallet=…   the recorded grant, or 404
//   GET  /healthz                     200

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { Faucet } from "./faucet.ts";

const MAX_BODY = 4 * 1024;

function send(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

export function faucetServer(faucet: Faucet): Server {
  return createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    try {
      if (req.method === "GET" && url.pathname === "/healthz") return send(res, 200, { ok: true });
      if (req.method === "GET" && url.pathname === "/v1/grant") {
        const record = faucet.lookup(url.searchParams.get("chain") ?? "", url.searchParams.get("wallet") ?? "");
        return record ? send(res, 200, record) : send(res, 404, { error: "no grant" });
      }
      if (req.method === "POST" && url.pathname === "/v1/grant") {
        let body: { chain?: unknown; wallet?: unknown };
        try {
          body = JSON.parse(await readBody(req)) as typeof body;
        } catch {
          return send(res, 400, { error: "body must be JSON" });
        }
        const result = await faucet.grant(String(body.chain ?? ""), String(body.wallet ?? ""));
        if (!result.ok) return send(res, result.status, { error: result.error, failedStep: result.failedStep });
        return send(res, result.existing ? 200 : 201, result.record);
      }
      return send(res, 404, { error: "not found" });
    } catch (error) {
      return send(res, 500, { error: error instanceof Error ? error.message : String(error) });
    }
  });
}
