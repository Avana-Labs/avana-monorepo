// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Convex part of the services check (services-smoke.sh), on a local Convex deployment already running from
// services/convex: sets its environment (Convex's own RPC, the indexer export and its key, the listing content URL),
// writes the chain's deployment row from the release manifest, imports the indexer's export to the finalized head,
// samples the current values and waits for the listing metadata to load. Then every market of the manifest must have
// its pool page, and every debt reserve its asset page, with the numbers read on chain and the text of the listing
// metadata file its listing operation committed to (its salt; one file per listing operation, all read).
//
// Usage, from contracts/:  node script/e2e/convex-check.ts <manifest.json> <repo root>
// Environment: RPC_ANVIL, E2E_EXPORT_URL, E2E_EXPORT_KEY_ID, E2E_EXPORT_SECRET, E2E_LISTING_CONTENT_URL.

import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

type Json = Record<string, any>;
const [manifestPath, repo] = process.argv.slice(2) as [string, string];
const env = (n: string) => {
  const v = process.env[n];
  if (!v) throw new Error(`set ${n}`);
  return v;
};
const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as Json;
const OUT = dirname(manifestPath);
const CONVEX_DIR = join(repo, "services/convex");
// The CLI's own entry point, run with this node: node_modules/.bin/convex is a shell script, which Windows cannot run
// (and its convex.cmd would need a shell, which mangles the JSON arguments).
const CONVEX = join(repo, "node_modules/convex", JSON.parse(readFileSync(join(repo, "node_modules/convex/package.json"), "utf8")).bin.convex);

/** One `convex` CLI call on the local deployment; `run` answers with the function's JSON result. */
function convex(args: string[]): string {
  return execFileSync(process.execPath, [CONVEX, ...args], { cwd: CONVEX_DIR, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
}
function run<T>(fn: string, args: Json = {}): T {
  const out = convex(["run", fn, JSON.stringify(args)]).trim();
  return (out === "" || out === "null" ? null : JSON.parse(out)) as T;
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const lower = (a: string) => a.toLowerCase();

async function main() {
  const chainId = Number(manifest.chainId);
  for (const [k, v] of Object.entries({
    RPC_ANVIL: env("RPC_ANVIL"),
    INDEXER_EXPORT_URL: env("E2E_EXPORT_URL"),
    INDEXER_EXPORT_KEY_ID: env("E2E_EXPORT_KEY_ID"),
    INDEXER_EXPORT_SECRET: env("E2E_EXPORT_SECRET"),
    LISTING_CONTENT_URL: env("E2E_LISTING_CONTENT_URL"),
  }))
    convex(["env", "set", k, v]);

  const world = JSON.parse(readFileSync(join(OUT, "world.json"), "utf8")) as Json;
  run("deployments:setDeployment", {
    chainId,
    lens: manifest.avana.lens.address,
    hubs: manifest.aave.hubs.map((h: Json) => ({ address: h.address, label: h.label, tier: h.tier })),
    lendSpokes: manifest.aave.lendSpokes.map((s: Json) => s.address),
    cdpSpokes: manifest.aave.borrowSpokes.map((s: Json) => s.address),
    firstLossReserves: manifest.avana.firstLossReserves.map((c: Json) => ({ address: c.address, asset: c.asset, hub: c.hub })),
    marketRegistry: manifest.avana.marketRegistry.address,
    timelock: manifest.avana.timelock.address,
    explorerUrl: "http://127.0.0.1:8545",
    nativeUsdFeed: world.feeds.WETH.primary,
    release: manifest.release,
  });

  // The export serves up to the finalized block: import until the checkpoint stops moving.
  let through = -1;
  for (let i = 0; i < 60; i++) {
    run("ingest/pull:pull", { chainId });
    const s = run<{ checkpoint: { throughBlock: string } | null }>("ingest/apply:state", { chainId });
    const at = s?.checkpoint ? Number(s.checkpoint.throughBlock) : -1;
    if (at === through && at > 0) break;
    through = at;
  }
  if (through <= 0) throw new Error("Convex imported no export page from the indexer");
  run("ingest/sampler:refresh", { chainId });

  // Every listing operation committed to its own metadata file (listing-content/<hash>.json, its salt): the first
  // deployment's, then one per later listing. listing-metadata.json points only at the latest, or at none when the
  // last 09-market-metadata found nothing new, so the check reads them all.
  const dir = join(OUT, "listing-content");
  const files = readdirSync(dir).filter((f) => f.endsWith(".json"));
  if (files.length === 0) throw new Error(`no listing metadata file in ${dir}`);
  const entries = files.flatMap((f) => (JSON.parse(readFileSync(join(dir, f), "utf8")) as Json).entries as Json[]);
  const entry = (scope: string, key: string) => {
    const e = entries.find((x) => x.scope === scope && x.key === key);
    if (!e) throw new Error(`no listing metadata file has a ${scope} entry ${key}`);
    return e;
  };

  // The listing operation's metadata loads in a scheduled action after its CallExecuted is imported.
  const first = entry("pool", String(manifest.markets[0].marketId));
  let content: Json | null = null;
  for (let i = 0; i < 30 && !content; i++) {
    content = run<Json | null>("marketContent:get", { scope: "pool", slug: first.slug });
    if (!content) await sleep(2000);
  }
  if (!content) throw new Error(`no listing content loaded from ${env("E2E_LISTING_CONTENT_URL")} for pool ${first.slug}`);
  // Each later listing operation's file loads in its own scheduled action: wait for every entry's text.
  const pending = () => entries.filter((e) => (e.scope === "pool" || e.scope === "asset") && !run<Json | null>("marketContent:get", { scope: e.scope, slug: e.slug }));
  for (let i = 0; i < 30 && pending().length > 0; i++) await sleep(2000);
  const missing = pending();
  if (missing.length > 0) {
    // The latest listing operation's record says whether its file loaded, was refused (and why) or was not found.
    const latest = JSON.parse(readFileSync(join(OUT, "operation-listing-markets.json"), "utf8")) as Json;
    const op = run<Json | null>("listing/load:operation", { chainId, operationId: latest.id });
    process.stdout.write(`convex: listing operation ${latest.id} (salt ${latest.salt}): ${JSON.stringify(op)}\n`);
  }

  const failures: string[] = [];
  const lines: string[] = [];
  const page = (scope: "pool" | "asset", e: Json, check: (row: Json) => string | null) => {
    const row = run<Json | null>("markets:getMarketSnapshot", { scope, slug: e.slug });
    const text = run<Json | null>("marketContent:get", { scope, slug: e.slug });
    const problem = !row
      ? "no page"
      : row.name !== e.name || row.description !== e.description
        ? `name or description is not the listing's (${row.name})`
        : !text || text.faqs?.length !== e.faqs.length || text.longText !== e.longText
          ? "listing text missing"
          : check(row);
    (problem ? failures : lines).push(`${scope} ${e.slug}: ${problem ?? `${row!.name}; ${JSON.stringify(pick(row!))}`}`);
  };
  for (const m of manifest.markets as Json[]) {
    const e = entry("pool", String(m.marketId));
    const cf = (config().listing.markets as Json[]).find((c) => c.content?.slug === e.slug)?.collateralFactorBps;
    page("pool", e, (r) =>
      r.maxLtvPct !== cf / 100
        ? `collateral factor ${r.maxLtvPct} %, listed ${cf / 100} %`
        : !(r.lpPriceUsd > 0)
          ? "no accepted price"
          : !(r.availableUsd > 0)
            ? "no cap headroom"
            : r.spokeId !== lower(m.spoke)
              ? `Spoke ${r.spokeId}, listed ${m.spoke}`
              : null,
    );
  }
  for (const d of manifest.debtReserves as Json[]) {
    const e = entry("asset", `${lower(d.spoke)}:${d.debtReserveId}`);
    page("asset", e, (r) => (r.spokeId !== undefined && lower(r.spokeId) !== lower(d.spoke) ? `Spoke ${r.spokeId}` : !(r.availableUsd >= 0) ? "no Hub liquidity read" : null));
  }
  for (const l of lines) process.stdout.write(`convex: ${l}\n`);
  for (const f of failures) process.stdout.write(`convex: FAIL ${f}\n`);
  process.stdout.write(`convex: ${lines.length} pages with data and text, ${failures.length} failed; export imported through block ${through}\n`);
  if (failures.length > 0) process.exit(1);
}

function pick(r: Json) {
  const o: Json = {};
  for (const k of ["maxLtvPct", "lpPriceUsd", "availableUsd", "suppliedUsd", "borrowAprPct", "supplyApyPct"]) if (r[k] !== undefined) o[k] = r[k];
  return o;
}

let cfg: Json | undefined;
function config(): Json {
  cfg ??= JSON.parse(
    readFileSync(join(repo, "contracts", process.env.AVANA_CONFIG ?? `script/deploy/config/${manifest.network}.json`), "utf8"),
  ) as Json;
  return cfg!;
}

main().catch((e: unknown) => {
  const err = e as Error & { stderr?: string };
  process.stdout.write(`convex: FAIL ${err.message}${err.stderr ? `\n${err.stderr.slice(-1500)}` : ""}\n`);
  process.exit(1);
});
