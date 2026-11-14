// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The ingest endpoint keeper instances (through their log shipper) post to, and the status endpoint. Each instance
// has its own bearer token; a request may only report for that instance. Bodies are capped at 256 KiB.
//
//   POST /v1/keeper/alerts     { "instance": "...", "alerts": [ <keeper.alert line>, ... ] }
//   POST /v1/keeper/heartbeat  { "instance": "...", "blockNumber": "123" }
//   GET  /v1/status            open alerts (status token)
//   GET  /healthz              200 while the process runs

import { createHash, timingSafeEqual } from "node:crypto";
import { type IncomingMessage, type Server, type ServerResponse, createServer } from "node:http";
import { type KeeperAlertLine, type KeeperFeed, type KeeperInstance, refusal } from "./keeper.ts";
import type { Alert } from "./types.ts";

const MAX_BODY = 256 * 1024;

export interface ServerConfig {
  /** Instance name → its bearer token. */
  readonly keeperTokens: ReadonlyMap<string, string>;
  readonly statusToken: string;
}

const digest = (s: string) => createHash("sha256").update(s).digest();
const same = (a: string, b: string) => timingSafeEqual(digest(a), digest(b));

function bearer(req: IncomingMessage): string | null {
  const h = req.headers.authorization;
  return h?.startsWith("Bearer ") ? h.slice(7) : null;
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error("body too large"));
        req.destroy();
      } else chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

const json = (res: ServerResponse, status: number, body: unknown) => res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));

export function monitorServer(cfg: ServerConfig, feed: KeeperFeed, openAlerts: () => readonly Alert[]): Server {
  const instances = new Map<string, KeeperInstance>(feed.instances.map((i) => [i.name, i]));
  for (const name of instances.keys()) if (!cfg.keeperTokens.get(name)) throw new Error(`no token for keeper instance ${name}`);

  return createServer(async (req, res) => {
    try {
      if (req.method === "GET" && req.url === "/healthz") return json(res, 200, { ok: true });
      const token = bearer(req);
      if (req.method === "GET" && req.url === "/v1/status") {
        if (token === null || !same(token, cfg.statusToken)) return json(res, 401, { error: "unauthorized" });
        return json(res, 200, { open: openAlerts().map((a) => ({ ...a, blockNumber: a.blockNumber.toString(10) })) });
      }
      if (req.method !== "POST" || (req.url !== "/v1/keeper/alerts" && req.url !== "/v1/keeper/heartbeat")) return json(res, 404, { error: "not found" });

      let body: { instance?: unknown; alerts?: unknown; blockNumber?: unknown };
      try {
        body = JSON.parse(await readBody(req));
      } catch (err) {
        return json(res, 400, { error: err instanceof Error ? err.message : "bad body" });
      }
      const inst = typeof body.instance === "string" ? instances.get(body.instance) : undefined;
      // Unknown instance and wrong token answer alike, so the endpoint does not reveal instance names.
      if (!inst || token === null || !same(token, cfg.keeperTokens.get(inst.name)!)) return json(res, 401, { error: "unauthorized" });

      if (req.url === "/v1/keeper/heartbeat") {
        if (typeof body.blockNumber !== "string" || !/^\d{1,20}$/.test(body.blockNumber)) return json(res, 400, { error: "blockNumber must be a decimal string" });
        feed.heartbeat(inst, BigInt(body.blockNumber));
        return json(res, 200, { ok: true });
      }

      if (!Array.isArray(body.alerts)) return json(res, 400, { error: "alerts must be an array" });
      const refused: { index: number; reason: string }[] = [];
      body.alerts.forEach((line: KeeperAlertLine, index: number) => {
        const why = line && typeof line === "object" ? refusal(inst, line) : "not an object";
        if (why) refused.push({ index, reason: why });
        else feed.alert(inst, line);
      });
      return json(res, refused.length > 0 ? 422 : 200, { accepted: body.alerts.length - refused.length, refused });
    } catch (err) {
      return json(res, 500, { error: err instanceof Error ? err.message : "error" });
    }
  });
}
