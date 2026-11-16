// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Drives the local Convex deployment's chain jobs for the local chains, which its crons do not schedule (they name
// Ethereum and Base): the export pull (every 30 s on the local Ethereum, 10 s on the local Base), the current-value
// sampler (30 s) and the intent tracker (12 s and 4 s), the same functions and intervals as services/convex/convex/
// crons.ts. Calls go to the deployment's HTTP API with its admin key (STACK/convex.json, written by the stack), one at
// a time per job; a failed call is logged and retried at the next interval.
//
// Usage: node script/local/convex-driver.ts

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { CHAINS, STACK } from "./lib/env.ts";

const { url, adminKey } = JSON.parse(readFileSync(join(STACK, "convex.json"), "utf8")) as { url: string; adminKey: string };

async function call(kind: "action" | "mutation", path: string, args: Record<string, unknown>): Promise<unknown> {
  const r = await fetch(`${url}/api/${kind}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Convex ${adminKey}` },
    body: JSON.stringify({ path, args, format: "json" }),
  });
  const j = (await r.json()) as { status: string; value?: unknown; errorMessage?: string };
  if (j.status !== "success") throw new Error(j.errorMessage ?? `HTTP ${r.status}`);
  return j.value;
}

const jobs = CHAINS.flatMap((c) => [
  { name: `pull ${c.chainId}`, kind: "action" as const, path: "ingest/pull:pull", args: { chainId: c.chainId }, every: c.blockTime >= 12 ? 30_000 : 10_000 },
  { name: `sample ${c.chainId}`, kind: "action" as const, path: "ingest/sampler:refresh", args: { chainId: c.chainId }, every: 30_000 },
  { name: `intents ${c.chainId}`, kind: "action" as const, path: "intents:track", args: { chainId: c.chainId }, every: c.blockTime >= 12 ? 12_000 : 4_000 },
]);

const log = (o: Record<string, unknown>) => process.stdout.write(`${JSON.stringify({ t: new Date().toISOString(), ...o })}\n`);
for (const j of jobs) {
  let busy = false;
  const tick = async () => {
    if (busy) return;
    busy = true;
    try {
      await call(j.kind, j.path, j.args);
    } catch (e) {
      log({ job: j.name, error: (e as Error).message.slice(0, 400) });
    } finally {
      busy = false;
    }
  };
  void tick();
  setInterval(tick, j.every);
}
log({ msg: "driving", jobs: jobs.map((j) => j.name) });
