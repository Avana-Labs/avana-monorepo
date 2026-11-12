// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Authenticated halt and resume endpoint (mutual TLS, on its own port). A halt stops new submissions at once and
// is written to disk before it is acknowledged, so it survives a restart. A halted keeper keeps scanning and
// logging; its pending transactions expire at their 3-block deadline.

import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { createServer } from "node:https";
import type { TLSSocket } from "node:tls";
import type { SafetyState } from "./guards.ts";

interface HaltRecord {
  readonly halted: boolean;
  readonly by: string;
  readonly at: string;
}

/** Reads the persisted flag; an unreadable file counts as halted (fail closed). */
export function readHalt(path: string): boolean {
  if (!existsSync(path)) return false;
  try {
    return (JSON.parse(readFileSync(path, "utf8")) as HaltRecord).halted !== false;
  } catch {
    return true;
  }
}

function writeHalt(path: string, record: HaltRecord): void {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(record), { mode: 0o600 });
  renameSync(tmp, path);
}

export interface KillSwitchOptions {
  readonly port: number;
  readonly cert: string;
  readonly key: string;
  readonly clientCa: string;
  readonly statePath: string;
}

/** Starts the endpoint. `POST /halt`, `POST /resume`, `GET /state`; every request needs a client certificate from the CA. */
export function startKillSwitch(opts: KillSwitchOptions, state: SafetyState, onChange: (halted: boolean, by: string) => void) {
  state.halted = readHalt(opts.statePath);
  const server = createServer(
    {
      cert: readFileSync(opts.cert),
      key: readFileSync(opts.key),
      ca: readFileSync(opts.clientCa),
      requestCert: true,
      rejectUnauthorized: true,
      minVersion: "TLSv1.3",
    },
    (req, res) => {
      const peer = (req.socket as TLSSocket).getPeerCertificate();
      // A subject may carry several CN attributes (Node returns them as an array); the audit record names them all.
      const cn = peer?.subject?.CN;
      const by = (Array.isArray(cn) ? cn.join("+") : cn) || "unknown";
      const route = `${req.method} ${req.url}`;
      if (route === "GET /state") {
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ halted: state.halted }));
        return;
      }
      if (route !== "POST /halt" && route !== "POST /resume") {
        res.writeHead(404).end();
        return;
      }
      const halted = route === "POST /halt";
      writeHalt(opts.statePath, { halted, by, at: new Date().toISOString() });
      state.halted = halted;
      onChange(halted, by);
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ halted }));
    },
  );
  server.listen(opts.port);
  return server;
}
