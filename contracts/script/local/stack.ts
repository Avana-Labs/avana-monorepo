// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The local stack the webapp runs on (README.md in this folder): two anvil chains, a local Ethereum (31337, 12 s
// blocks) and a local Base (31338, 2 s blocks), Avana deployed on each, the indexer and a local Convex for both, the
// keeper, the monitor, a market-activity loop per chain and the webapp.
//
// Usage, from contracts/:
//   node script/local/stack.ts up [--chains ethereum,base] [--no-activity] [--no-hubs] [--no-webapp]
//   node script/local/stack.ts deploy [--chains ...]   the chains and their first release only, no services
//   node script/local/stack.ts status
//   node script/local/stack.ts secrets          store the fork RPC URLs, encrypted next to the keystores (prompted)
//   node script/local/stack.ts check            re-check only: manifests, indexer at head, Convex against the chain
//   node script/local/stack.ts replay           the indexer replay and replay-check.ts against the local Convex
//   node script/local/stack.ts add-hub <hub.json> --chain ethereum|base
//   node script/local/stack.ts down [--keep-chains]
//   node script/local/stack.ts reset            after `down`: every chain's outputs and the services' stores (keystores kept)
//
// `up` resumes: each deploy step that passed is skipped, the first one that failed runs again, and every process that
// is already running is kept. A failure stops `up` with the step and its log and leaves every node and service running,
// so the fix is checked by running `up` (or `check`) again, in minutes, without a redeploy.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { CHAINS, CONTRACTS, type LocalChain, PORTS, STACK, chainOf, manifestPath, outDir, rpcUrl } from "./lib/env.ts";
import { FIRST_RELEASE, answers, blockNumber, currentConfig, fundSigners, miningMode, placeL1FeeOracle, readStatus, runRelease, setMining, startNode, stopNode, writeBaseConfig } from "./lib/chain.ts";
import { ensureKeys } from "./lib/keys.ts";
import { names, record, running, start, stop } from "./lib/procs.ts";
import {
  CONVEX_DIR,
  PGLITE,
  WEBAPP_DIR,
  convexInfo,
  indexerAtHead,
  indexerStatus,
  startContent,
  startConvex,
  startConvexDriver,
  startIndexer,
  startKeeper,
  startMonitor,
  startRecorders,
  stopServices,
} from "./lib/services.ts";

const argv = process.argv.slice(2);
const cmd = argv[0];
const flag = (n: string) => argv.includes(`--${n}`);
const opt = (n: string) => {
  const i = argv.indexOf(`--${n}`);
  return i === -1 ? undefined : argv[i + 1];
};
const say = (s: string) => process.stdout.write(`${s}\n`);
const selected = (): LocalChain[] => (opt("chains") ? opt("chains")!.split(",").map(chainOf) : [...CHAINS]);

class Stop extends Error {}

/** One chain: its node, its signers' gas, its base config and its first release. */
async function upChain(c: LocalChain): Promise<void> {
  const node = await startNode(c);
  say(`${c.label} (${c.chainId}): node ${node} on ${rpcUrl(c)}`);
  await fundSigners(c);
  await placeL1FeeOracle(c);
  const status = readStatus(c);
  const config = status.config ? currentConfig(c) : writeBaseConfig(c);
  const deployed = status.steps["first:manifest"]?.outcome === "pass";
  if (deployed) say(`${c.label}: first release on record (${Object.keys(status.steps).length} steps); running only what is missing`);
  await setMining(c, "auto");
  const t0 = Date.now();
  const done = await runRelease(c, "first", FIRST_RELEASE, config, (o) => {
    if (o.outcome !== "skipped") say(`  ${o.outcome.toUpperCase().padEnd(5)} ${c.network} ${o.step}${o.outcome === "fail" ? `: ${o.detail}` : ""}`);
  });
  const failed = done.find((o) => o.outcome === "fail");
  if (failed) throw new Stop(`${c.label}: ${failed.step} failed (log ${failed.log}). Every node and service is still running: fix it and run \`up\` again; the passed steps are not rerun.`);
  if (!deployed) say(`${c.label}: first release deployed in ${Math.round((Date.now() - t0) / 60_000)} min`);
}

async function up(): Promise<void> {
  ensureKeys();
  const chains = selected();
  for (const c of chains) await upChain(c);
  if (CHAINS.some((c) => !existsSync(manifestPath(c)))) say(`not every chain is deployed yet: services start on ${CHAINS.filter((c) => existsSync(manifestPath(c))).map((c) => c.label).join(", ")}`);
  await startRecorders();
  say("rpc-recorders: running");
  await startIndexer();
  say(`indexer: ready on http://127.0.0.1:${PORTS.indexer}`);
  // Steady state: blocks on the chains' own clock from here on.
  for (const c of CHAINS) if (await answers(c)) await setMining(c, "interval");
  const at = await indexerAtHead();
  say(`indexer: at head ${JSON.stringify(at)}`);
  await startContent();
  const info = await startConvex();
  say(`convex: ${info.url} (functions from ${CONVEX_DIR})`);
  startConvexDriver();
  await startMonitor();
  say(`monitor: running on port ${PORTS.monitor}`);
  await startKeeper();
  say(`keeper: active on ${CHAINS.filter((c) => existsSync(manifestPath(c))).map((c) => c.label).join(", ")}`);
  if (!flag("no-activity")) {
    for (const c of CHAINS.filter((x) => existsSync(manifestPath(x)))) {
      const name = `activity-${c.key}`;
      if (!running(name)) start(name, process.execPath, [join(CONTRACTS, "script/local/activity.ts"), "--chain", c.network], { cwd: CONTRACTS });
    }
    say("activity: running on every deployed chain");
  }
  if (!flag("no-hubs")) await applyHubFiles();
  if (!flag("no-webapp")) startWebapp();
  await writeEnvFile();
  say(`stack up: ${join(STACK, "stack.env")} lists the endpoints`);
}

/** The Hub files of each chain (script/deploy/hubs/<network>/*.json, world.json aside), in name order: each one not
 * released yet runs through the operator flow on the running stack, so its markets appear as any later Hub's would. */
async function applyHubFiles(): Promise<void> {
  const { readdirSync } = await import("node:fs");
  const { addHub } = await import("./operator/hub.ts");
  for (const c of CHAINS.filter((x) => existsSync(manifestPath(x)))) {
    const dir = join(CONTRACTS, "script/deploy/hubs", c.network);
    if (!existsSync(dir)) continue;
    for (const f of readdirSync(dir).filter((x) => x.endsWith(".json") && x !== "world.json").sort()) {
      const label = (JSON.parse(readFileSync(join(dir, f), "utf8")) as { hub: { label: string } }).hub.label;
      if (readStatus(c).steps[`hub-${label}:manifest`]?.outcome === "pass") continue;
      say(`${c.label}: Hub file ${f}`);
      const r = await addHub({ chain: c.network, hubFile: join(dir, f) }, (o) => {
        if (o.outcome !== "skipped") say(`  ${o.outcome.toUpperCase().padEnd(5)} ${c.network} ${o.step}${o.outcome === "fail" ? `: ${o.detail}` : ""}`);
      });
      if (!r.ok) throw new Stop(`${c.label}: Hub file ${f}: ${r.error ?? r.steps.find((s) => s.outcome === "fail")?.detail}. Everything is still running: fix it and run \`up\` again.`);
      say(`${c.label}: ${f} released: ${r.markets?.length ?? 0} markets`);
      restartActivity(c);
    }
  }
}

/** The activity loop reads the chain's markets at start: restarted after a release adds some. */
function restartActivity(c: LocalChain): void {
  const name = `activity-${c.key}`;
  if (!running(name)) return;
  stop(name);
  start(name, process.execPath, [join(CONTRACTS, "script/local/activity.ts"), "--chain", c.network], { cwd: CONTRACTS });
}

/** The webapp's dev server on the stack (its environment from stack.env), when its start command is known. */
function startWebapp(): void {
  if (running("webapp")) return;
  const script = join(WEBAPP_DIR, "scripts", "local-stack.mjs");
  if (!existsSync(script)) {
    say(`webapp: not started (${script} not found: the webapp's local-stack entry is the webapp session's)`);
    return;
  }
  start("webapp", process.execPath, [script, join(STACK, "stack.env")], { cwd: WEBAPP_DIR });
  say(`webapp: starting on http://127.0.0.1:${PORTS.webapp}`);
}

/** Endpoints and chain facts for the webapp and anyone else on the stack (no secret: those stay in STACK/secrets). */
async function writeEnvFile(): Promise<void> {
  const info = convexInfo();
  const lines = [
    "# Written by contracts/script/local/stack.ts: the local stack's endpoints. No secret or key is listed here.",
    `STACK_CONVEX_URL=${info?.url ?? ""}`,
    `STACK_CONVEX_SITE_URL=${info?.siteUrl ?? ""}`,
    `STACK_INDEXER_URL=http://127.0.0.1:${PORTS.indexer}`,
    `STACK_WEBAPP_URL=http://127.0.0.1:${PORTS.webapp}`,
    `STACK_CHAIN_IDS=${CHAINS.map((c) => c.chainId).join(",")}`,
  ];
  for (const c of CHAINS) {
    lines.push(`STACK_RPC_${c.chainId}=${rpcUrl(c)}`, `STACK_BLOCK_TIME_${c.chainId}=${c.blockTime}`, `STACK_MANIFEST_${c.chainId}=${manifestPath(c)}`);
  }
  lines.push(`STACK_FAUCET_KEYSTORE=${join(STACK, "keystore", "faucet")}`, `STACK_KEYSTORE_PASSWORD_FILE=${join(STACK, "keystore", "password")}`);
  writeFileSync(join(STACK, "stack.env"), `${lines.join("\n")}\n`);
}

async function status(): Promise<void> {
  for (const c of CHAINS) {
    const s = readStatus(c);
    const steps = Object.entries(s.steps);
    const failed = steps.filter(([, r]) => r.outcome === "fail").map(([k]) => k);
    const live = await answers(c);
    say(`${c.label} (${c.chainId}, ${c.network}): node ${live ? `block ${await blockNumber(c)}, mining ${await miningMode(c)}` : "down"}; ${steps.filter(([, r]) => r.outcome === "pass").length} steps passed${failed.length ? `, failed: ${failed.join(", ")}` : ""}; manifest ${existsSync(manifestPath(c)) ? "yes" : "no"}`);
  }
  for (const n of names()) say(`  ${n.padEnd(22)} ${running(n) ? "running" : "stopped"} pid ${record(n)?.pid} log ${record(n)?.log}`);
  try {
    say(`indexer: ${JSON.stringify(await indexerStatus())}`);
  } catch {
    say("indexer: not answering");
  }
  const info = convexInfo();
  if (info) say(`convex: ${info.url}`);
}

async function down(): Promise<void> {
  for (const n of stopServices()) say(`stopped ${n}`);
  if (!flag("keep-chains")) {
    for (const c of CHAINS) {
      await stopNode(c);
      say(`stopped ${c.label} node (state saved to ${outDir(c)}/anvil-state.hex)`);
    }
  }
}

/** Removes what a fresh stack must not reuse: each chain's outputs, broadcasts and saved state, the indexer store, the
 * local Convex deployment, the recorders' answers and the activity state. The keystores stay. Refused while running. */
async function reset(): Promise<void> {
  const live = names().filter((n) => running(n));
  if (live.length) throw new Stop(`still running: ${live.join(", ")}; run \`down\` first`);
  const { rmSync, readdirSync } = await import("node:fs");
  const gone: string[] = [];
  const rm = (p: string) => {
    if (existsSync(p)) {
      rmSync(p, { recursive: true, force: true });
      gone.push(p);
    }
  };
  for (const c of CHAINS) {
    rm(outDir(c));
    for (const d of ["broadcast", "cache"]) {
      const root = join(CONTRACTS, d);
      if (!existsSync(root)) continue;
      for (const s of readdirSync(root)) if (s.endsWith(".s.sol")) rm(join(root, s, String(c.chainId)));
    }
  }
  rm(PGLITE);
  rm(join(CONVEX_DIR, ".convex"));
  rm(join(CONVEX_DIR, ".env.local"));
  rm(join(STACK, "convex.json"));
  rm(join(STACK, "replay"));
  for (const c of CHAINS) rm(join(STACK, `activity-${c.key}.json`));
  say(`removed ${gone.length} paths; keystores kept in ${join(STACK, "keystore")}`);
}

async function main() {
  try {
    switch (cmd) {
      case "up":
        await up();
        break;
      case "secrets": {
        ensureKeys();
        const { promptSecrets } = await import("./lib/secrets.ts");
        await promptSecrets(say);
        break;
      }
      case "deploy":
        ensureKeys();
        for (const c of selected()) await upChain(c);
        break;
      case "status":
        await status();
        break;
      case "reset":
        await reset();
        break;
      case "down":
        await down();
        break;
      case "check": {
        const { check } = await import("./lib/check.ts");
        process.exitCode = (await check(selected(), say)) ? 0 : 1;
        break;
      }
      case "replay": {
        const { replay } = await import("./lib/check.ts");
        process.exitCode = (await replay(selected(), say)) ? 0 : 1;
        break;
      }
      case "add-hub": {
        const { addHub } = await import("./operator/hub.ts");
        const chain = chainOf(opt("chain") ?? "ethereum");
        const result = await addHub({ chain: chain.network, hubFile: argv[1]! }, (o) => say(JSON.stringify(o)));
        if (result.ok) restartActivity(chain);
        say(JSON.stringify(result, null, 2));
        process.exitCode = result.ok ? 0 : 1;
        break;
      }
      default:
        say("usage: node script/local/stack.ts up|status|check|replay|add-hub <hub.json> --chain <network>|down");
        process.exitCode = 2;
    }
  } catch (e) {
    say(e instanceof Stop ? `STOPPED ${e.message}` : `FAILED ${(e as Error).stack ?? e}`);
    process.exitCode = 1;
  }
}

await main();
