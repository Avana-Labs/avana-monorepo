// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Convex part of the services check (services-smoke.sh), on a local Convex deployment already running from
// services/convex: sets its environment (Convex's own RPC, the indexer export and its key), writes the chain's
// deployment row from the release manifest itself (deployments:setFromManifest), imports the indexer's export to the
// finalized head and samples the current values. Then every market of the manifest must have its pool page (the
// default slug `<chain>-market-<integrationId>-<marketId>`: each integration's RiskModule numbers its own markets) on
// its Spoke with the market's LTV, a price and borrowable headroom, and
// every debt reserve its asset page on its Spoke with the Hub's liquidity read.
//
// Usage, from contracts/:  node script/e2e/convex-check.ts <manifest.json> <repo root>
// Environment: RPC_ANVIL, E2E_EXPORT_URL, E2E_EXPORT_KEY_ID, E2E_EXPORT_SECRET.

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

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

// On Windows, `convex run` prints its result and then aborts on a libuv assertion while exiting (Node 24); that exit
// alone is not a failure.
const EXIT_ABORT = /^(Assertion failed: !\(handle->flags & UV_HANDLE_CLOSING\), file src\\win\\async\.c, line \d+\s*)+$/;

/** One `convex` CLI call on the local deployment; `run` answers with the function's JSON result. */
function convex(args: string[]): string {
  const r = spawnSync(process.execPath, [CONVEX, ...args], { cwd: CONVEX_DIR, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  if (r.error) throw r.error;
  if (r.status !== 0 && !(process.platform === "win32" && EXIT_ABORT.test(r.stderr.trim())))
    throw new Error(`convex ${args.slice(0, 2).join(" ")} exited ${r.status ?? r.signal}: ${r.stderr.trim()}`);
  return r.stdout;
}
function run<T>(fn: string, args: Json = {}): T {
  const out = convex(["run", fn, JSON.stringify(args)]).trim();
  return (out === "" || out === "null" ? null : JSON.parse(out)) as T;
}
const lower = (a: string) => a.toLowerCase();

async function main() {
  const chainId = Number(manifest.chainId);
  for (const [k, v] of Object.entries({
    // The node stands in for Ethereum: Convex reads it as RPC_MAINNET with CHAIN_ID_MAINNET.
    RPC_MAINNET: env("RPC_ANVIL"),
    CHAIN_ID_MAINNET: "31337",
    INDEXER_EXPORT_URL: env("E2E_EXPORT_URL"),
    INDEXER_EXPORT_KEY_ID: env("E2E_EXPORT_KEY_ID"),
    INDEXER_EXPORT_SECRET: env("E2E_EXPORT_SECRET"),
  }))
    convex(["env", "set", k, v]);

  const world = JSON.parse(readFileSync(join(OUT, "world.json"), "utf8")) as Json;
  run("deployments:setFromManifest", { manifest, explorerUrl: "http://127.0.0.1:8545", nativeUsdFeed: world.feeds.WETH.primary });

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

  // Convex's own default page slugs (services/convex/convex/lib/format.ts, no imports).
  const { defaultSlug } = (await import(pathToFileURL(join(CONVEX_DIR, "convex/lib/format.ts")).href)) as {
    defaultSlug: { pool: (c: number, integrationId: number, id: string) => string };
  };
  const rows = run<Json[]>("markets:listMarketSnapshots") ?? [];
  const symbolOf = new Map(Object.entries((world.tokens ?? {}) as Record<string, string>).map(([sym, a]) => [lower(a), sym]));

  const failures: string[] = [];
  const lines: string[] = [];
  const report = (what: string, problem: string | null, row: Json | null) => (problem ? failures : lines).push(`${what}: ${problem ?? `${row!.name}; ${JSON.stringify(pick(row!))}`}`);
  // Market IDs are per RiskModule: Convex keys a market by (chain, integration, market ID), so two integrations'
  // markets of one ID have two pages, each on its own Spoke.
  const slugs = new Set<string>();
  for (const m of manifest.markets as Json[]) {
    const slug = defaultSlug.pool(chainId, Number(m.integrationId), String(m.marketId));
    const row = run<Json | null>("markets:getMarketSnapshot", { scope: "pool", slug });
    report(
      `pool ${slug} (${m.name}, ${m.kind}, integration ${m.integrationId})`,
      slugs.has(slug)
        ? "a second market of the manifest has this page"
        : !row
          ? "no page"
          : lower(row.spokeId ?? "") !== lower(m.spoke)
            ? `Spoke ${row.spokeId}, listed ${m.spoke}`
            : row.maxLtvPct !== m.ltvBps / 100
              ? `LTV ${row.maxLtvPct} %, listed ${m.ltvBps / 100} %`
              : !(row.lpPriceUsd > 0)
                ? "no price"
                : !(row.availableUsd > 0)
                  ? "nothing borrowable"
                  : null,
      row,
    );
    slugs.add(slug);
  }
  for (const d of manifest.debtReserves as Json[]) {
    const sym = symbolOf.get(lower(d.asset)) ?? d.asset;
    const row = rows.find((r) => r.scope === "asset" && lower(r.spokeId ?? "") === lower(d.spoke) && (r.symbol === sym || lower(r.symbol ?? "") === lower(d.asset))) ?? null;
    report(`asset ${sym} on ${d.spoke} (reserve ${d.debtReserveId})`, !row ? "no page" : !(row.availableUsd >= 0) ? "no Hub liquidity read" : null, row);
  }
  for (const l of lines) process.stdout.write(`convex: ${l}
`);
  for (const f of failures) process.stdout.write(`convex: FAIL ${f}
`);
  process.stdout.write(`convex: ${lines.length} pages with data, ${failures.length} failed; export imported through block ${through}
`);
  if (failures.length > 0) process.exit(1);
}

function pick(r: Json) {
  const o: Json = {};
  for (const k of ["maxLtvPct", "lpPriceUsd", "availableUsd", "suppliedUsd", "borrowAprPct", "supplyApyPct"]) if (r[k] !== undefined) o[k] = r[k];
  return o;
}

main().catch((e: unknown) => {
  const err = e as Error & { stderr?: string };
  process.stdout.write(`convex: FAIL ${err.message}${err.stderr ? `
${err.stderr.slice(-1500)}` : ""}
`);
  process.exit(1);
});
