// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The stack's checks, run against the running stack (nothing is redeployed or restarted that need not be):
//   check   re-check only, in minutes: each chain's manifest against the chain, the indexer at both heads, and Convex
//           against the chain (contracts/script/e2e/replay-check.ts, Convex mode) at the last closed daily sample.
//   replay  the indexer replay (services/REPLAY.md) on the stack: two sampler blocks a day apart close a daily bucket on
//           each chain, the live indexer stops at the head, a second indexer indexes every block again into a fresh
//           schema from Ponder's sync store and the rpc-recorders, its tables must equal the live pass's
//           (replay-check.ts --indexer), the live indexer starts again, and replay-check.ts checks the local Convex
//           against each chain.
// While a check runs, the chains mine a block per transaction and the activity loops pause (STACK/activity.paused), so
// the heads stand still; both are restored afterwards.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { CONTRACTS, EXPORT_KEY_ID, type LocalChain, PORTS, REPO, STACK, chainIdEnv, manifestPath, rpcUrl } from "./env.ts";
import { answers, blockNumber, refreshFeeds, rpc, setMining, stepEnv } from "./chain.ts";
import { logPath, running, sleep, stop } from "./procs.ts";
import { PGLITE, indexerAtHead, indexerUrl, secret, startIndexer } from "./services.ts";

type Say = (s: string) => void;
const PAUSE = join(STACK, "activity.paused");
const sampleFile = (c: LocalChain) => join(STACK, "replay", `sample-block-${c.key}`);

/** Ponder's warning, error and fatal lines of a log, less the node's own notices (services-replay.sh `classify`). */
export function classify(log: string): { errors: string[]; tolerated: number } {
  const node = new Set(["All JSON-RPC providers are inactive", "All JSON-RPC providers are inactive due to rate limiting", "No new block received within expected time", "JSON-RPC request unexpectedly surpassed timeout"]);
  const errors: string[] = [];
  let tolerated = 0;
  if (!existsSync(log)) return { errors, tolerated };
  for (const line of readFileSync(log, "utf8").split(/\r?\n/)) {
    if (!/"level":(40|50|60)[,}]/.test(line)) continue;
    let j: { level: number; msg: string; error?: { message?: string } };
    try {
      j = JSON.parse(line);
    } catch {
      errors.push(line);
      continue;
    }
    const timeout = j.msg === "Received JSON-RPC error" && /took too long to respond/.test(j.error?.message ?? "");
    if (j.level === 40 && (j.msg.startsWith("Detected public RPC URL") || node.has(j.msg) || timeout)) tolerated++;
    else errors.push(line);
  }
  return { errors, tolerated };
}

/** Holds the chains still for a check and puts them back afterwards. */
async function still<T>(chains: readonly LocalChain[], body: () => Promise<T>): Promise<T> {
  mkdirSync(STACK, { recursive: true });
  writeFileSync(PAUSE, new Date().toISOString());
  await sleep(3_000);
  for (const c of chains) if (await answers(c)) await setMining(c, "auto");
  try {
    return await body();
  } finally {
    for (const c of chains) if (await answers(c)) await setMining(c, "interval");
    rmSync(PAUSE, { force: true });
  }
}

function node(args: string[], env: NodeJS.ProcessEnv, log: string, cwd = CONTRACTS): { ok: boolean; out: string } {
  const r = spawnSync(process.execPath, args, { cwd, env: { ...process.env, ...env }, encoding: "utf8", maxBuffer: 1 << 28 });
  const out = `${r.stdout ?? ""}${r.stderr ?? ""}`;
  writeFileSync(log, out, { flag: "a" });
  return { ok: r.status === 0, out };
}

function verifyManifest(c: LocalChain, say: Say): boolean {
  const log = logPath(`check-${c.key}-manifest`);
  rmSync(log, { force: true });
  const r = node([join(REPO, "packages/protocol/src/manifest/cli.ts"), "verify", "--manifest", manifestPath(c), "--rpc-env", "RPC_STACK"], { RPC_STACK: rpcUrl(c) }, log, join(REPO, "packages/protocol"));
  say(`${r.ok ? "PASS" : "FAIL"} ${c.network} manifest: ${r.out.trim().split(/\r?\n/).at(-1)}${r.ok ? "" : ` (log ${log})`}`);
  return r.ok;
}

/** replay-check.ts in Convex mode for one chain, on the local Convex fed by the live indexer. */
function convexCheck(c: LocalChain, sample: number, say: Say): boolean {
  const log = logPath(`check-${c.key}-convex`);
  rmSync(log, { force: true });
  const r = node([join(CONTRACTS, "script/e2e/replay-check.ts"), manifestPath(c), REPO], {
    RPC_ANVIL: rpcUrl(c),
    ...chainIdEnv(),
    E2E_EXPORT_URL: indexerUrl(),
    E2E_EXPORT_KEY_ID: EXPORT_KEY_ID,
    E2E_EXPORT_SECRET: secret("export-secret"),
    E2E_SAMPLE_BLOCK: String(sample),
    E2E_LISTING_CONTENT_URL: `http://127.0.0.1:${PORTS.content}`,
  }, log);
  const lines = r.out.trim().split(/\r?\n/);
  for (const l of lines.filter((x) => /FAIL/.test(x)).slice(0, 15)) say(`  ${l.slice(0, 400)}`);
  say(`${r.ok ? "PASS" : "FAIL"} ${c.network} convex: ${lines.at(-1)} (log ${log})`);
  return r.ok;
}

/** The sampler's start block and interval on the chain (services/indexer ponder.config.ts, samplerSource). */
function sampler(c: LocalChain): { start: number; every: number } {
  const m = JSON.parse(readFileSync(manifestPath(c), "utf8")) as Record<string, any>;
  const firstLend = Math.min(...m.aave.lendSpokes.map((s: { startBlock: number }) => s.startBlock));
  return { start: Math.max(m.avana.lens.startBlock, firstLend), every: Math.round(3_600 / c.blockTime) };
}

/** Moves the chain a day on, mines to the next sampler block, and returns it. */
async function nextSample(c: LocalChain): Promise<number> {
  await rpc(rpcUrl(c), "evm_increaseTime", [90_000]);
  await rpc(rpcUrl(c), "evm_mine");
  refreshFeeds(c, { ...process.env, ...stepEnv(c) }, logPath(`check-${c.key}-feeds`));
  const { start, every } = sampler(c);
  const head = await blockNumber(c);
  const next = start + (Math.floor((head - start) / every) + 1) * every;
  await rpc(rpcUrl(c), "anvil_mine", [`0x${(next - head).toString(16)}`]);
  return next;
}

/** Two sampler blocks a day apart (a daily bucket closes at the second), then 70 blocks past anvil's finality. */
async function closeSamples(c: LocalChain, say: Say): Promise<number> {
  const s1 = await nextSample(c);
  const s2 = await nextSample(c);
  await rpc(rpcUrl(c), "anvil_mine", ["0x46"]);
  mkdirSync(join(STACK, "replay"), { recursive: true });
  writeFileSync(sampleFile(c), String(s1));
  say(`${c.network}: samples at blocks ${s1} and ${s2}, head ${await blockNumber(c)}`);
  return s1;
}

export async function check(chains: readonly LocalChain[], say: Say): Promise<boolean> {
  return still(chains, async () => {
    let ok = true;
    for (const c of chains) ok = verifyManifest(c, say) && ok;
    for (const c of chains) if (!existsSync(sampleFile(c))) await closeSamples(c, say);
    else await rpc(rpcUrl(c), "anvil_mine", ["0x46"]);
    try {
      say(`PASS indexer at head ${JSON.stringify(await indexerAtHead(300_000))}`);
    } catch (e) {
      say(`FAIL indexer: ${(e as Error).message}`);
      return false;
    }
    const live = classify(logPath("indexer"));
    say(`${live.errors.length ? "FAIL" : "PASS"} indexer log: ${live.errors.length} error or warning lines, ${live.tolerated} node timeouts or notices`);
    ok = live.errors.length === 0 && ok;
    for (const c of chains) ok = convexCheck(c, Number(readFileSync(sampleFile(c), "utf8")), say) && ok;
    return ok;
  });
}

export async function replay(chains: readonly LocalChain[], say: Say): Promise<boolean> {
  return still(chains, async () => {
    let ok = true;
    if (!running("indexer")) throw new Error("no live indexer: run the stack's up command first");
    for (const c of chains) await closeSamples(c, say);
    say(`indexer (live): at head ${JSON.stringify(await indexerAtHead(600_000))}`);
    const live = classify(logPath("indexer"));
    say(`indexer (live): ${live.errors.length} error or warning lines, ${live.tolerated} node timeouts or notices`);
    for (const l of live.errors.slice(0, 5)) say(`  ${l.slice(0, 500)}`);
    stop("indexer");
    await sleep(3_000);

    // Every block again, from the manifests' start blocks, into a schema no run has written.
    const schema = `replay_${Date.now()}`;
    rmSync(logPath("indexer-replay"), { force: true });
    try {
      await startIndexer(schema, "indexer-replay");
      say(`indexer (${schema}): at head ${JSON.stringify(await indexerAtHead(1_800_000))}`);
    } catch (e) {
      say(`FAIL indexer replay: ${(e as Error).message}`);
      ok = false;
    }
    const rep = classify(logPath("indexer-replay"));
    say(`${rep.errors.length ? "FAIL" : "PASS"} indexer (replay): ${rep.errors.length} error or warning lines, ${rep.tolerated} node timeouts or notices`);
    for (const l of rep.errors.slice(0, 10)) say(`  ${l.slice(0, 600)}`);
    ok = ok && rep.errors.length === 0;
    stop("indexer-replay");
    await sleep(3_000);

    // The two schemas hold the same rows (read with both indexers stopped: PGlite takes one process).
    if (ok) {
      const log = logPath("check-indexer-tables");
      rmSync(log, { force: true });
      const r = node([join(CONTRACTS, "script/e2e/replay-check.ts"), "--indexer", REPO, PGLITE, "live", schema], chainIdEnv(), log);
      say(`${r.ok ? "PASS" : "FAIL"} indexer tables: ${r.out.trim().split(/\r?\n/).filter((l) => /replay: /.test(l)).join(" | ").slice(0, 800)}`);
      ok = r.ok && ok;
    }

    await startIndexer("live", "indexer");
    say(`indexer (live): restarted, at head ${JSON.stringify(await indexerAtHead(600_000))}`);
    for (const c of chains) ok = convexCheck(c, Number(readFileSync(sampleFile(c), "utf8")), say) && ok;
    for (const c of chains) say(`${c.network}: rpc-recorder ${await (await fetch(`http://127.0.0.1:${c.recorderPort}`)).text().catch(() => "?")}`);
    return ok;
  });
}
