// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The stack's checks, run against the running stack (nothing is redeployed or restarted that need not be):
//   check   re-check only, in minutes: each chain's manifest against the chain, the indexer at both heads, Convex
//           against the chain (contracts/script/e2e/replay-check.ts, Convex mode) at the last closed daily sample, and
//           the liquidation fee split (feeSplit.ts).
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
import { encodeFunctionData, parseAbi, toFunctionSelector } from "viem";
import { CONTRACTS, EXPORT_KEY_ID, type LocalChain, PORTS, REPO, STACK, chainIdEnv, manifestPath, outDir, rpcUrl } from "./env.ts";
import { answers, blockNumber, refreshFeeds, rpc, setMining, stateFloor, stepEnv } from "./chain.ts";
import { logPath, running, sleep, stop } from "./procs.ts";
import { PGLITE, indexerAtHead, indexerUrl, runningLiveSchema, secret, startIndexer } from "./services.ts";

type Say = (s: string) => void;
const PAUSE = join(STACK, "activity.paused");
const sampleFile = (c: LocalChain) => join(STACK, "replay", `sample-block-${c.key}`);

/** Ponder's warning, error and fatal lines of a log, less the node's own notices (services-replay.sh `classify`). */
/**
 * How long the indexer may take to reach the heads. Closing the samples mines a sampler interval on each chain (an hour
 * of blocks: 1,800 on the 2 s Base chain), and the indexer takes new blocks one at a time, about two a second.
 */
const INDEXER_CATCH_UP_MS = 1_800_000;

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

/**
 * The samples a check reads: the last ones closed, or new ones when there are none or the last is before the chain's
 * state floor (a node restored from a saved state can no longer read it). The chain then mines past anvil's finality.
 * Closing samples mines an hour of blocks per sample, which the live indexer takes long to follow on a 2-second chain,
 * so they are reused; deleting `deployments-local/stack/replay/sample-block-<chain>` closes new ones.
 */
async function samples(c: LocalChain, say: Say): Promise<void> {
  const last = existsSync(sampleFile(c)) ? Number(readFileSync(sampleFile(c), "utf8")) : undefined;
  if (last === undefined || last < (await stateFloor(c))) {
    await closeSamples(c, say);
    return;
  }
  await rpc(rpcUrl(c), "anvil_mine", ["0x46"]);
  say(`${c.network}: samples at block ${last} (last closed), head ${await blockNumber(c)}`);
}

export async function check(chains: readonly LocalChain[], say: Say): Promise<boolean> {
  return still(chains, async () => {
    let ok = true;
    for (const c of chains) ok = verifyManifest(c, say) && ok;
    for (const c of chains) await samples(c, say);
    try {
      say(`PASS indexer at head ${JSON.stringify(await indexerAtHead(INDEXER_CATCH_UP_MS))}`);
    } catch (e) {
      say(`FAIL indexer: ${(e as Error).message}`);
      return false;
    }
    const live = classify(logPath("indexer"));
    say(`${live.errors.length ? "FAIL" : "PASS"} indexer log: ${live.errors.length} error or warning lines, ${live.tolerated} node timeouts or notices`);
    ok = live.errors.length === 0 && ok;
    for (const c of chains) ok = convexCheck(c, Number(readFileSync(sampleFile(c), "utf8")), say) && ok;
    for (const c of chains) ok = (await feeSplit(c, say)) && ok;
    for (const c of chains) ok = (await guardianAccess(c, say)) && ok;
    return ok;
  });
}

/** REQ-ACCESS-070 on the deployed chain: the Aave Protocol Guardian can call the SpokeConfigurator's one-way
 * `freezeReserve` and `pauseReserve`, and not their two-way setters nor any other configurator selector checked. */
async function guardianAccess(c: LocalChain, say: Say): Promise<boolean> {
  const { addresses } = await import("./keys.ts");
  const aave = JSON.parse(readFileSync(join(outDir(c), "aave.json"), "utf8")) as Record<string, string>;
  const abi = parseAbi(["function canCall(address caller, address target, bytes4 selector) view returns (bool immediate, uint32 delay)"]);
  const want: Record<string, boolean> = {
    "freezeReserve(address,uint256)": true,
    "pauseReserve(address,uint256)": true,
    "updateFrozen(address,uint256,bool)": false,
    "updatePaused(address,uint256,bool)": false,
    "freezeAllReserves(address)": false,
    "pauseAllReserves(address)": false,
    "updateBorrowable(address,uint256,bool)": false,
  };
  const wrong: string[] = [];
  for (const [sig, allowed] of Object.entries(want)) {
    const data = encodeFunctionData({ abi, functionName: "canCall", args: [addresses().guardian, aave.spokeConfigurator as `0x${string}`, toFunctionSelector(sig)] });
    const out = await rpc<string>(rpcUrl(c), "eth_call", [{ to: aave.accessManager, data }, "latest"]);
    if ((BigInt(out.slice(0, 66)) === 1n) !== allowed) wrong.push(`${sig} ${allowed ? "refused" : "allowed"}`);
  }
  say(`${wrong.length ? "FAIL" : "PASS"} ${c.network} Aave Protocol Guardian: freezeReserve and pauseReserve only${wrong.length ? ` (${wrong.join(", ")})` : ""}`);
  return wrong.length === 0;
}

/** The liquidation fee split (feeSplit.ts): fail on any settlement that pays other than the spec says. */
async function feeSplit(c: LocalChain, say: Say): Promise<boolean> {
  const { checkFeeSplit } = await import("./feeSplit.ts");
  const r = await checkFeeSplit(c);
  for (const f of r.failures.slice(0, 10)) say(`  ${f}`);
  say(`${r.ok ? "PASS" : "FAIL"} ${c.network} fee split: ${r.settlements} liquidations${r.settlements === 0 ? " (none yet: the activity loop's scripted liquidation makes one)" : ""}, ${r.failures.length} failures`);
  return r.ok;
}

export async function replay(chains: readonly LocalChain[], say: Say): Promise<boolean> {
  return still(chains, async () => {
    let ok = true;
    if (!running("indexer")) throw new Error("no live indexer: run the stack's up command first");
    for (const c of chains) await samples(c, say);
    say(`indexer (live): at head ${JSON.stringify(await indexerAtHead(INDEXER_CATCH_UP_MS))}`);
    const live = classify(logPath("indexer"));
    say(`indexer (live): ${live.errors.length} error or warning lines, ${live.tolerated} node timeouts or notices`);
    for (const l of live.errors.slice(0, 5)) say(`  ${l.slice(0, 500)}`);
    const liveName = runningLiveSchema();
    stop("indexer");
    await sleep(3_000);

    // Every block again, from the manifests' start blocks, into a schema no run has written.
    const schema = `replay_${Date.now()}`;
    rmSync(logPath("indexer-replay"), { force: true });
    try {
      await startIndexer(schema, "indexer-replay");
      say(`indexer (${schema}): at head ${JSON.stringify(await indexerAtHead(INDEXER_CATCH_UP_MS))}`);
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
      const r = node([join(CONTRACTS, "script/e2e/replay-check.ts"), "--indexer", REPO, PGLITE, liveName, schema], chainIdEnv(), log);
      say(`${r.ok ? "PASS" : "FAIL"} indexer tables: ${r.out.trim().split(/\r?\n/).filter((l) => /replay: /.test(l)).join(" | ").slice(0, 800)}`);
      ok = r.ok && ok;
    }

    // A Hub release since the live indexer started changes its build: it then restarts on a new schema from the start blocks.
    await startIndexer();
    say(`indexer (live): restarted on ${runningLiveSchema()}, at head ${JSON.stringify(await indexerAtHead(INDEXER_CATCH_UP_MS))}`);
    for (const c of chains) ok = convexCheck(c, Number(readFileSync(sampleFile(c), "utf8")), say) && ok;
    for (const c of chains) say(`${c.network}: rpc-recorder ${await (await fetch(`http://127.0.0.1:${c.recorderPort}`)).text().catch(() => "?")}`);
    return ok;
  });
}
