// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One local chain of the stack: its anvil node, the deploy and release steps run through script/deploy/step.sh, each
// recorded in deployments-local/<network>/stack-status.json, and the release manifest. A step that passed is never run
// again; a step that failed is run again (with forge's --start-fresh) by the next call, on the same node: the fix of a
// failed step costs that step, not a redeploy.
// The public test networks (env.ts TESTNETS, script/testnet/testnet.ts) run the same steps from the same configs, with
// no anvil method: their signers are keystores, a timelock delay is waited on the chain's clock, the executor stand-in
// is deployed by a transaction, and the steps that only feed the local services are skipped.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { CONTRACTS, type LocalChain, REPO, activeRpcProvider, activeRpcUrls, genesisTimestamp, outDir, rpcUrl } from "./env.ts";
import { testnetRoles, testnetSignerEnv } from "../../testnet/keys.ts";
import { broadcastSnapshot, changedBroadcasts, planFailover, redactRpc, testnetRpc, useHealthyRpc } from "../../testnet/rpc.ts";
import { addresses, signerEnv } from "./keys.ts";
import { minObservations } from "./forkPools.ts";
import { dumpState, firstStateBlock, hexStateToJson } from "./state.ts";
import { logPath, running, start, stop, waitFor } from "./procs.ts";

// ─── JSON-RPC ───

export async function rpc<T = unknown>(url: string, method: string, params: unknown[] = []): Promise<T> {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = (await r.json()) as { result?: T; error?: { message: string } };
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result as T;
}

export const blockNumber = async (c: LocalChain) => Number(BigInt(await rpc<string>(rpcUrl(c), "eth_blockNumber")));
export const answers = async (c: LocalChain) => {
  try {
    return (await rpc<string>(rpcUrl(c), "eth_chainId")) !== undefined;
  } catch {
    return false;
  }
};

// ─── The node ───

const nodeName = (c: LocalChain) => `anvil-${c.key}`;
export const statePath = (c: LocalChain) => join(outDir(c), "anvil-state.json");
/** The state as the stack saved it before it streamed states: anvil_dumpState's hex. `startNode` converts it once. */
const legacyStatePath = (c: LocalChain) => join(outDir(c), "anvil-state.hex");

/**
 * Starts the chain's anvil node unless one answers on its port: its chain ID, the rehearsal's code-size and gas limits,
 * every sender unlocked for the governance stand-ins, and an optional fork. It starts mining a block per transaction
 * (deploys and releases are not paced by the block time); `setMining(c, "interval")` then mines one block every
 * `blockTime` seconds, as the chain does. A state saved by `stopNode` is loaded back (`--load-state`); a state saved
 * as hex by an earlier stack is converted to anvil's JSON state first.
 */
export async function startNode(c: LocalChain): Promise<"running" | "started" | "restored"> {
  if (await answers(c)) {
    const id = Number(BigInt(await rpc<string>(rpcUrl(c), "eth_chainId")));
    if (id !== c.chainId) throw new Error(`port ${c.port} answers chain ${id}, not ${c.label} (${c.chainId}): stop that node or set STACK_PORT_*`);
    return "running";
  }
  mkdirSync(outDir(c), { recursive: true });
  const args = [
    "--host", "127.0.0.1", "--port", String(c.port), "--chain-id", String(c.chainId), "--auto-impersonate",
    "--code-size-limit", "49152", "--gas-limit", "60000000",
  ];
  if (!existsSync(statePath(c)) && existsSync(legacyStatePath(c))) await hexStateToJson(legacyStatePath(c), statePath(c));
  const restore = existsSync(statePath(c));
  if (restore) args.push("--load-state", statePath(c));
  if (c.fork) {
    await startForkProxy(c);
    args.push("--fork-url", `http://127.0.0.1:${c.fork.proxyPort}`, "--fork-block-number", String(c.fork.block), "--retries", "10", "--fork-retry-backoff", "2000", "--timeout", "60000");
  } else if (!restore) args.push("--timestamp", String(genesisTimestamp()));
  start(nodeName(c), "anvil", args);
  // A long-running chain's state is over a gigabyte of JSON: anvil answers once it has loaded it.
  await waitFor(`${c.label} node`, () => answers(c), restore ? 900_000 : 30_000, restore ? 2_000 : 300);
  return restore ? "restored" : "started";
}

/** The chain's fork proxy, holding the network's RPC endpoints (environment or encrypted secrets) in its environment. */
async function startForkProxy(c: LocalChain): Promise<void> {
  const name = `fork-proxy-${c.key}`;
  if (running(name)) return;
  const { secretValue } = await import("./secrets.ts");
  const varName = `${c.network.toUpperCase()}_FORK_RPC_URL` as "ETHEREUM_FORK_RPC_URL" | "BASE_FORK_RPC_URL";
  const urls = secretValue(varName);
  if (!urls) throw new Error(`fork mode needs ${varName}: set it in the environment, or store it encrypted with \`node script/local/stack.ts secrets --only ${varName}\``);
  start(name, process.execPath, [join(CONTRACTS, "script/local/fork-proxy.ts"), String(c.fork!.proxyPort)], { env: { FORK_UPSTREAMS: urls } });
  await waitFor(`${c.label} fork proxy`, async () => (await fetch(`http://127.0.0.1:${c.fork!.proxyPort}`)).ok, 15_000, 300);
}

/** Saves the node's state (anvil_dumpState, streamed to anvil's JSON state) and stops it. */
export async function stopNode(c: LocalChain, save = true): Promise<void> {
  if (save && (await answers(c))) await dumpState(rpcUrl(c), statePath(c));
  stop(nodeName(c));
  stop(`fork-proxy-${c.key}`);
}

export const nodeRunning = (c: LocalChain) => running(nodeName(c));

/**
 * The chain's state floor: the first block whose state the node serves. A node started from a saved state has every
 * block and log but no state before the block it was restored at; a read pinned earlier fails.
 */
export async function stateFloor(c: LocalChain): Promise<number> {
  const served = async (n: number) => {
    try {
      await rpc(rpcUrl(c), "eth_getBalance", ["0x0000000000000000000000000000000000000000", `0x${n.toString(16)}`]);
      return true;
    } catch {
      return false;
    }
  };
  return firstStateBlock(await blockNumber(c), served);
}

/**
 * `auto`: a block per transaction, no timer (deploys and releases, whose hundreds of transactions would otherwise wait
 * a block each). `interval`: a block every `blockTime` seconds, transactions wait for it, as on the real chain.
 */
export async function setMining(c: LocalChain, mode: "auto" | "interval"): Promise<void> {
  if (mode === "auto") await rpc(rpcUrl(c), "evm_setAutomine", [true]);
  else await rpc(rpcUrl(c), "evm_setIntervalMining", [c.blockTime]);
}

export async function miningMode(c: LocalChain): Promise<"auto" | "interval"> {
  return (await rpc<boolean>(rpcUrl(c), "anvil_getAutomine")) ? "auto" : "interval";
}

// ─── Config ───

/** The values the Aave DAO and governance set on a real network, for the local stack only (test-values.json). */
export const testValues = (): Record<string, any> => JSON.parse(readFileSync(join(CONTRACTS, "script/local/test-values.json"), "utf8"));

/**
 * The chain's first-release config: one Aave Hub for the chain (label `ethereum` or `base`, page "Avana <Chain> Hub",
 * tier 3, which takes stable, correlated and volatile markets) with its Lend Spoke and the debt assets, and no CDP Spoke
 * or market: the chain's Hub files add those (script/deploy/hubs/<chain>/). Built from the anvil config's protocol
 * parameters; the values the DAO sets (caps, First-Loss Reserve and offset amounts, speed limits) come
 * from test-values.json. The stack's keystores fill every role: the deployer is also the test tokens' minter and the
 * First-Loss Reserves' funder, the keeper is the keeper and the operator helper's signer, the treasury is the fee
 * recipient, the guardian is the Aave Protocol Guardian.
 */
export function writeBaseConfig(
  c: LocalChain,
  a: { deployer: string; keeper: string; treasury: string; guardian: string } = addresses(),
  patch?: (cfg: Record<string, any>) => void,
): string {
  const cfg = baseConfig(c, a, patch);
  const dst = join(outDir(c), "config-base.json");
  mkdirSync(outDir(c), { recursive: true });
  writeFileSync(dst, `${JSON.stringify(cfg, null, 2)}\n`);
  return dst;
}

/** The chain's first-release config (writeBaseConfig), built in memory: `a` fills the roles, `patch` changes the rest. */
export function baseConfig(
  c: LocalChain,
  a: { deployer: string; keeper: string; treasury: string; guardian: string },
  patch?: (cfg: Record<string, any>) => void,
): Record<string, any> {
  const src = JSON.parse(readFileSync(join(CONTRACTS, "script/deploy/config/anvil.json"), "utf8")) as Record<string, any>;
  const tv = testValues();
  const label = c.hubs;
  const lend = `lend${label.charAt(0).toUpperCase()}${label.slice(1)}`;
  const cfg = structuredClone(src);
  cfg.network = c.network;
  cfg.chainId = c.chainId;
  cfg.chain.blockTime = c.blockTime;
  // Every world pool keeps a 30-minute TWAP at this chain's block time: the LPOracle refuses a pool whose observation
  // cardinality is below twapMinObservations (anvil.json's 151 suits 12-second blocks, not Base's 2).
  cfg.world.observationCardinality = Math.max(Number(cfg.world.observationCardinality ?? 0), minObservations(TWAP_WINDOW, c.blockTime));
  // The MarketRegistry's MAX_MARKET_COUNT is fixed at deployment: room for every Hub file the stack may add.
  cfg.parameters.maxMarketCount = Number(process.env.STACK_MAX_MARKETS ?? 128);
  cfg.parameters.globals.feeRecipient = a.treasury;
  cfg.governance.aaveProtocolGuardian = a.guardian;
  cfg.keepers = [a.keeper];
  for (const h of cfg.operatorHelpers) h.signer = a.keeper;
  cfg.aavePayload.tokenMinter = a.deployer;
  cfg.coverage.funder = a.deployer;
  cfg.aaveLocal.hubs = [label];
  cfg.aaveLocal.spokes = [{ label: lend, userReservesLimit: 65535 }];
  cfg.aave.hubs = [{ hub: `$aave:.hubs.${label}.proxy`, tier: 3, label }];
  cfg.aave.irStrategies = { [label]: `$aave:.hubs.${label}.irStrategy` };
  cfg.aave.spokes = { [lend]: `$aave:.spokes.${lend}.proxy` };
  const name = `Avana ${c.label} Hub`;
  cfg.aavePayload.hubs = [{ label, lendSpoke: lend, cdpSpokes: [], content: { slug: `avana-${label}-hub`, name, description: `Avana's Aave V4 Hub on ${c.label}.`, faqs: [] } }];
  for (const d of cfg.aavePayload.debtAssets) {
    const v = tv.debtAssets?.[d.symbol] ?? {};
    for (const k of ["drawCap", "bootstrapSupply", "coverageMinimum", "offsetMinimum", "rateModel", "liquidityFeeBps"]) if (v[k] !== undefined) d[k] = v[k];
  }
  cfg.listing.speedLimits = tv.speedLimits;
  cfg.listing.spokes = [];
  cfg.listing.debtReserves = [];
  // A listing debt asset (its Chainlink feed or fixed price, its rounding allowance) needs a CDP Spoke to price it: the Hub
  // file that makes the asset borrowable lists it, with the Spoke (planHub, from the test values).
  cfg.listing.debtAssets = [];
  // The protocol's market parameters a Hub file's market starts from, per integration (1 Uniswap v3, 2 Slipstream, 3 Uniswap v4),
  // taken from the anvil config's first market of each; the market list itself starts empty.
  const template = (id: number) => {
    const { name: _n, spoke: _s, pool: _p, routes: _r, content: _c, ...rest } = (src.listing.markets as Record<string, any>[]).find((m) => m.integrationId === id)!;
    return rest;
  };
  cfg.listing.marketDefaults = Object.fromEntries(
    [1, 2, 3].filter((id) => (src.listing.markets as Record<string, any>[]).some((m) => m.integrationId === id)).map((id) => [String(id), template(id)]),
  );
  cfg.listing.markets = [];
  cfg.listing.pools = {};
  cfg.listing.uniswapV4Pools = {};
  for (const t of cfg.listing.tokens) {
    t.hubs = [label];
    Object.assign(t, tv.tokens?.default ?? {}, tv.tokens?.[t.symbol] ?? {});
  }
  // The chain's Hub files may need tokens and pools the test world lacks: script/deploy/hubs/<hubs>/world.json
  // adds them to the world step 02 deploys (an entry already in the world is kept as it is).
  const extra = join(CONTRACTS, "script/deploy/hubs", c.hubs, "world.json");
  if (existsSync(extra)) {
    const w = JSON.parse(readFileSync(extra, "utf8")) as Record<string, { symbol?: string; name?: string }[]>;
    for (const k of ["tokens", "uniswapPools", "slipstreamPools", "uniswapV4Pools"]) {
      if (!w[k]) continue;
      cfg.world[k] ??= [];
      const have = new Set((cfg.world[k] as { symbol?: string; name?: string }[]).map((x) => x.symbol ?? x.name));
      for (const x of w[k] ?? []) if (!have.has(x.symbol ?? x.name)) cfg.world[k].push(x);
    }
  }
  patch?.(cfg);
  return cfg;
}

/** The config the chain's steps read now: the last release's (STATUS.config), else the base config. */
export function currentConfig(c: LocalChain): string {
  const s = readStatus(c);
  return s.config ? join(CONTRACTS, s.config) : join(outDir(c), "config-base.json");
}

// ─── The step ledger ───

export interface StepRecord {
  readonly outcome: "pass" | "fail";
  readonly detail: string;
  readonly at: string;
  readonly seconds: number;
  /** Test networks: the RPC provider the step ran on last. */
  readonly provider?: string;
  /** Test networks: the step failed on an RPC failure after it began broadcasting, so the next run continues its
   * broadcast (forge script --resume) instead of starting it again. */
  readonly resume?: boolean;
}
export interface Status {
  /** The config of the last release started (relative to contracts/). */
  config?: string;
  steps: Record<string, StepRecord>;
}
const statusPath = (c: LocalChain) => join(outDir(c), "stack-status.json");
export function readStatus(c: LocalChain): Status {
  return existsSync(statusPath(c)) ? (JSON.parse(readFileSync(statusPath(c), "utf8")) as Status) : { steps: {} };
}
function writeStatus(c: LocalChain, s: Status) {
  mkdirSync(outDir(c), { recursive: true });
  writeFileSync(statusPath(c), `${JSON.stringify(s, null, 2)}\n`);
}
export function setConfig(c: LocalChain, configPath: string) {
  const s = readStatus(c);
  s.config = relative(CONTRACTS, configPath).split("\\").join("/");
  writeStatus(c, s);
}

/** The chain's forge broadcast and cache directories (relative to contracts/), the cache seeded from the shared one so
 * nothing recompiles. */
export function forgeDirs(c: LocalChain): Record<string, string> {
  const broadcast = `deployments-local/${c.network}/forge-broadcast`;
  const cache = `deployments-local/${c.network}/forge-cache`;
  const seeded = join(CONTRACTS, cache, "solidity-files-cache.json");
  const shared = join(CONTRACTS, "cache", "solidity-files-cache.json");
  if (!existsSync(seeded) && existsSync(shared)) {
    mkdirSync(join(CONTRACTS, cache), { recursive: true });
    writeFileSync(seeded, readFileSync(shared));
  }
  return { FOUNDRY_BROADCAST: broadcast, FOUNDRY_CACHE_PATH: cache };
}

/** Git Bash on Windows (never WSL's bash, which would run the steps in another system); bash elsewhere. */
export function bash(): string {
  if (process.env.STACK_BASH) return process.env.STACK_BASH;
  if (process.platform !== "win32") return "bash";
  for (const p of ["C:\\Program Files\\Git\\bin\\bash.exe", "C:\\Program Files (x86)\\Git\\bin\\bash.exe"]) if (existsSync(p)) return p;
  throw new Error("Git Bash not found: set STACK_BASH to its bash.exe");
}

export interface StepOutcome {
  readonly chain: string;
  readonly step: string;
  readonly outcome: "pass" | "fail" | "skipped";
  readonly detail: string;
  readonly log?: string;
}

/** The environment of every step of the chain: its network, RPC, config and the stack's signers. */
export function stepEnv(c: LocalChain, config = currentConfig(c)): NodeJS.ProcessEnv {
  return {
    // Each chain's forge runs keep their broadcast records and script cache in the chain's own output directory, so
    // the two chains' steps never share a file (Windows refuses a file another forge has mapped, os error 1224). The
    // compiled artifacts stay shared in out/.
    ...forgeDirs(c),
    AVANA_NETWORK: c.network,
    AVANA_RPC_URL: rpcUrl(c),
    AVANA_CONFIG: relative(CONTRACTS, config).split("\\").join("/"),
    ...(c.testnet ? {} : { RPC_ANVIL: rpcUrl(c) }),
    [`RPC_${c.envSuffix}`]: rpcUrl(c),
    ...(c.testnet ? testnetSignerEnv() : signerEnv()),
  };
}

/** `text` with every secret replaced: the environment's (RPC URLs, provider credentials, the explorer key), and the
 * test networks' provider endpoints and credentials (script/testnet/rpc.ts). forge and viem name the URL in a
 * connection error, and a log must never hold it. */
export function redact(text: string): string {
  let out = text;
  for (const u of activeRpcUrls()) if (u.length >= 8) out = out.split(u).join("<AVANA_RPC_URL>");
  for (const [k, v] of Object.entries(process.env)) {
    if (v && v.length >= 8 && (/RPC_URL$|^RPC_|ETHERSCAN_API_KEY$|^ALCHEMY_API_KEY$|^QUICKNODE_(TOKEN|ENDPOINT_NAME)$/.test(k) || k === "AVANA_RPC_URL")) out = out.split(v).join(`<${k}>`);
  }
  return redactRpc(out);
}

/**
 * A step of the chain's release `release`: a named step of script/deploy/step.sh, `changes:<file>` (11-changes with a
 * changes file of deployments-local/<network>), or one of the stack's own (`multicall3`, `place-executor`,
 * `advance:<seconds>`, `manifest`, `treasury`). Passed steps are skipped.
 */
/**
 * `id` names the step in the ledger and its log: the step itself for its first run in a release, `<step>#<n>` for its
 * n-th (a release runs `advance:<s>` more than once, and each must run).
 */
export async function runStep(c: LocalChain, release: string, step: string, config = currentConfig(c), id = step): Promise<StepOutcome> {
  const key = `${release}:${id}`;
  const status = readStatus(c);
  const prev = status.steps[key];
  if (prev?.outcome === "pass") return { chain: c.network, step: key, outcome: "skipped", detail: prev.detail };
  const log = logPath(`${c.key}.${release}.${id.replace(/[:/#]/g, "-")}`);
  mkdirSync(join(log, ".."), { recursive: true });
  const t0 = Date.now();
  let ok = false;
  let detail = "";
  // A step whose earlier broadcast stopped part-way is run again from the start, its old broadcast record archived;
  // on a test network, one stopped by an RPC failure continues its broadcast instead (script/testnet/rpc.ts).
  let mode: ForgeMode = prev?.outcome === "fail" ? (prev.resume ? "resume" : "fresh") : "plain";
  const attempt = async (): Promise<string> => {
    const env = { ...process.env, ...stepEnv(c, config) };
    let d: string;
    if (step === "multicall3") d = c.testnet ? await checkMulticall3(c) : await placeMulticall3(c);
    else if (step === "place-executor") d = c.testnet ? await deployExecutor(c, config) : await placeExecutor(c, config);
    else if (step.startsWith("advance:")) d = c.testnet ? await waitOnChain(c, Number(step.slice(8)), env, log) : await advance(c, Number(step.slice(8)), env, log);
    else if (step === "twap-history") d = await waitForTwapHistory(c);
    else if (step === "manifest") d = manifest(c, env, log);
    else if (step === "treasury") d = c.testnet ? "skipped on a test network: the local faucet and activity loop are not deployed there" : await fundTreasuries(c);
    else if (step === "swap-contracts") d = await swapContracts(c);
    else if (step.startsWith("changes:")) d = runShell("11-changes", env, log, "plain", [join(outDir(c), step.slice(8))]);
    else d = runShell(step, env, log, mode);
    // An execute step whose timelock operation is not ready yet exits 0 and broadcasts nothing: that is a failure.
    const notReady = /^\s*not ready: .*$/m.exec(existsSync(log) ? readFileSync(log, "utf8") : "");
    if (notReady) throw new Error(notReady[0].trim());
    return d;
  };
  const broadcastDir = join(CONTRACTS, forgeDirs(c).FOUNDRY_BROADCAST!);
  let resume = false;
  try {
    // Each test-network step starts on the healthiest provider.
    if (c.testnet) await useHealthyRpc(c);
    const before = c.testnet ? broadcastSnapshot(broadcastDir) : undefined;
    try {
      detail = await attempt();
      ok = true;
    } catch (e) {
      detail = (e as Error).message;
      if (!c.testnet || !before) throw e;
      // An RPC failure: once more on the backup, after the failed attempt's transactions have settled there.
      const records = changedBroadcasts(broadcastDir, before);
      const output = `${detail}\n${existsSync(log) ? readFileSync(log, "utf8") : ""}`;
      const plan = await planFailover(c, output, records, Object.values(testnetRoles().signers));
      if (!plan.move) {
        const rpcFailure = plan.reason !== "not an RPC failure";
        resume = rpcFailure && records.length > 0;
        throw new Error(rpcFailure ? `${detail} (no failover: ${plan.reason})` : detail);
      }
      if (existsSync(log)) renameSync(log, `${log}.${plan.from}`);
      if (plan.resume) mode = "resume";
      try {
        detail = `${await attempt()} (moved from ${plan.from} to ${plan.to}${plan.resume ? ", broadcast resumed" : ""})`;
        ok = true;
      } catch (e2) {
        resume = plan.resume || changedBroadcasts(broadcastDir, before).length > 0;
        throw new Error(`${(e2 as Error).message} (after moving from ${plan.from} to ${plan.to}; the first attempt's log is ${log}.${plan.from})`);
      }
    }
  } catch (e) {
    detail = (e as Error).message;
  }
  const s = readStatus(c);
  const provider = c.testnet ? activeRpcProvider(c) : undefined;
  s.steps[key] = {
    outcome: ok ? "pass" : "fail",
    detail: redact(detail).slice(0, 600),
    at: new Date().toISOString(),
    seconds: Math.round((Date.now() - t0) / 1000),
    ...(provider ? { provider } : {}),
    ...(!ok && resume ? { resume } : {}),
  };
  writeStatus(c, s);
  return { chain: c.network, step: key, outcome: ok ? "pass" : "fail", detail: redact(detail), log };
}

/** How a forge step starts: as it is, from the start (`--start-fresh`), or continuing its broadcast (`--resume`). */
type ForgeMode = "plain" | "fresh" | "resume";

function runShell(step: string, env: NodeJS.ProcessEnv, log: string, mode: ForgeMode, args: string[] = []): string {
  const flag = mode === "fresh" ? "--start-fresh" : mode === "resume" ? "--resume" : "";
  const e = { ...env, AVANA_FORGE_FLAGS: [env.AVANA_FORGE_FLAGS ?? "", flag].join(" ").trim() };
  const run = () => spawnSync(bash(), ["script/deploy/step.sh", step, ...args], { cwd: CONTRACTS, env: e, encoding: "utf8", maxBuffer: 1 << 28 });
  let r = run();
  // A shell that failed to start wrote nothing and sent nothing: it is started once more.
  if (r.status !== 0 && !r.stdout && !r.stderr) r = run();
  // A step that never ran (the shell could not start, or was killed) leaves no output: its cause goes to the log.
  const lost = r.error ? `step.sh did not run: ${r.error.message}\n` : r.signal ? `step.sh stopped by ${r.signal}\n` : "";
  const text = redact(`${lost}${r.stdout ?? ""}${r.stderr ?? ""}`);
  writeFileSync(log, text);
  if (r.status !== 0) {
    const why = text.split(/\r?\n/).filter((l) => /Error|revert|error/.test(l)).slice(0, 3).join(" ") || text.trim().split(/\r?\n/).slice(-3).join(" ");
    throw new Error(`see ${log}: ${why}`);
  }
  return text.split(/\r?\n/).filter((l) => /BLOCKED|output|nothing|no new/.test(l)).slice(0, 3).join(" ");
}

/** Multicall3 at its canonical address with the recorded code hash (contracts/external/multicall3/README.md). */
async function placeMulticall3(c: LocalChain): Promise<string> {
  const address = "0xcA11bde05977b3631167028862bE2a173976CA11";
  const code = `0x${readFileSync(join(CONTRACTS, "external/multicall3/Multicall3.runtime.hex"), "utf8").trim().replace(/^0x/, "")}`;
  await rpc(rpcUrl(c), "anvil_setCode", [address, code]);
  const { keccak256 } = await import("viem");
  const h = keccak256((await rpc<`0x${string}`>(rpcUrl(c), "eth_getCode", [address, "latest"])) as `0x${string}`);
  if (h !== "0xd5c15df687b16f2ff992fc8d767b4216323184a2bbc6ee2f9c398c318e770891") throw new Error(`Multicall3 code hash ${h}`);
  return `code hash ${h}`;
}

/** On a test network Multicall3 is already deployed (its keyless transaction): its code hash is checked. */
async function checkMulticall3(c: LocalChain): Promise<string> {
  const { keccak256 } = await import("viem");
  const code = await rpc<`0x${string}`>(rpcUrl(c), "eth_getCode", ["0xcA11bde05977b3631167028862bE2a173976CA11", "latest"]);
  const h = keccak256(code);
  if (h !== "0xd5c15df687b16f2ff992fc8d767b4216323184a2bbc6ee2f9c398c318e770891") throw new Error(`Multicall3 code hash ${h}: not the canonical Multicall3`);
  return `code hash ${h}`;
}

/** The Safe Singleton Factory, on every network the deploy reaches (step 00 checks it). */
export const SAFE_SINGLETON_FACTORY = "0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7";

/**
 * A test network's Aave governance executor stand-in (AaveGovernanceExecutorOwnedStandIn), owned by `owner`, the
 * PayloadsController stand-in: its init code and the address the Safe Singleton Factory gives it with salt 0, so the
 * config names it before it is deployed.
 */
export async function executorStandIn(owner: string): Promise<{ address: `0x${string}`; initCode: `0x${string}` }> {
  const { encodeAbiParameters, getContractAddress } = await import("viem");
  const art = JSON.parse(readFileSync(join(CONTRACTS, "out/AaveGovernanceExecutorOwnedStandIn.sol/AaveGovernanceExecutorOwnedStandIn.json"), "utf8"));
  const initCode = `${art.bytecode.object}${encodeAbiParameters([{ type: "address" }], [owner as `0x${string}`]).slice(2)}` as `0x${string}`;
  const address = getContractAddress({ opcode: "CREATE2", from: SAFE_SINGLETON_FACTORY, salt: `0x${"00".repeat(32)}`, bytecode: initCode });
  return { address, initCode };
}

/** Deploys the executor stand-in through the Safe Singleton Factory, signed by the deployer keystore (before step 01:
 * Aave V4's deployment makes it admin). Its address must be the config's Aave DAO account. */
async function deployExecutor(c: LocalChain, config: string): Promise<string> {
  const cfg = JSON.parse(readFileSync(config, "utf8")) as Record<string, any>;
  const dao = (cfg.aaveLocal.aaveDao as string).toLowerCase();
  const controller = cfg.aaveLocal.payloadsController as string;
  const { address, initCode } = await executorStandIn(controller);
  if (address.toLowerCase() !== dao) throw new Error(`the executor stand-in for ${controller} lands at ${address}, not the config's aaveLocal.aaveDao ${dao}: rebuild or regenerate the config`);
  if ((await rpc<string>(rpcUrl(c), "eth_getCode", [address, "latest"])) !== "0x") return `executor stand-in at ${address} already`;
  const { wallet, client } = await deployerClients(c);
  const hash = await wallet.sendTransaction({ to: SAFE_SINGLETON_FACTORY, data: `0x${"00".repeat(32)}${initCode.slice(2)}`, chain: null });
  const r = await client.waitForTransactionReceipt({ hash });
  if (r.status !== "success" || (await rpc<string>(rpcUrl(c), "eth_getCode", [address, "latest"])) === "0x") throw new Error(`executor stand-in deployment ${hash} failed`);
  const { recordCreated } = await import("../../testnet/verify.ts");
  recordCreated(outDir(c), address, initCode);
  return `executor stand-in at ${address}, owner ${controller} (tx ${hash})`;
}

/** The deployer's wallet and a public client on the chain: the local stack's keystore, or the test network's. */
async function deployerClients(c: LocalChain) {
  const { createPublicClient, createWalletClient, http } = await import("viem");
  const { keystoreAccount, signerAccount } = await import("../../testnet/keys.ts");
  const { PASSWORD_FILE, keystorePath } = await import("./keys.ts");
  const account = c.testnet ? await signerAccount("deployer") : await keystoreAccount(keystorePath("deployer"), PASSWORD_FILE);
  // A test network sends through the RPC manager: a send whose outcome is unknown is looked up on the backup, never
  // signed again.
  const transport = c.testnet ? (await testnetRpc()).transport(c.chainId) : http(rpcUrl(c), { timeout: 120_000 });
  return {
    account,
    wallet: createWalletClient({ account, transport }),
    client: createPublicClient({ transport }),
  };
}

/**
 * A timelock delay on a test network: waits until the chain's clock has moved `seconds` past now (blocks keep coming
 * on a live chain), then publishes a fresh round on every feed, as on anvil.
 */
async function waitOnChain(c: LocalChain, seconds: number, env: NodeJS.ProcessEnv, log: string): Promise<string> {
  const now = async () => Number(BigInt((await rpc<{ timestamp: string }>(rpcUrl(c), "eth_getBlockByNumber", ["latest", false])).timestamp));
  const until = (await now()) + seconds;
  const t0 = Date.now();
  while ((await now()) < until) await new Promise((r) => setTimeout(r, Math.min(5_000, c.blockTime * 1_000)));
  refreshFeeds(c, env, log);
  return `waited ${Math.round((Date.now() - t0) / 1000)} s for ${seconds} s of chain time`;
}

/** The world pools' TWAP window, seconds: the listing checks each pool's `observe([TWAP_WINDOW, 0])`. */
export const TWAP_WINDOW = 1800;
/** `observe(uint32[])` of Uniswap v3 and Slipstream pools, with [TWAP_WINDOW, 0]. */
const OBSERVE_WINDOW = `0x883bdbfd${[0x20, 2, TWAP_WINDOW, 0].map((n) => n.toString(16).padStart(64, "0")).join("")}`;

/**
 * A test network's listing waits until every Uniswap v3 and Slipstream world pool has a TWAP window of history: a pool
 * answers `observe` over the window only once its first observation is that old, and the world's last pools are
 * created at the end of a long step 02. On anvil the timelock advance moves the clock days ahead, so this never waits.
 */
async function waitForTwapHistory(c: LocalChain): Promise<string> {
  const world = JSON.parse(readFileSync(join(outDir(c), "world.json"), "utf8")) as Record<string, Record<string, string> | undefined>;
  const pools = [...Object.values(world.uniswapPools ?? {}), ...Object.values(world.slipstreamPools ?? {})];
  const now = async () => Number(BigInt((await rpc<{ timestamp: string }>(rpcUrl(c), "eth_getBlockByNumber", ["latest", false])).timestamp));
  const young = async () => {
    const out: string[] = [];
    for (const p of pools) await rpc(rpcUrl(c), "eth_call", [{ to: p, data: OBSERVE_WINDOW }, "latest"]).catch(() => out.push(p));
    return out;
  };
  const t0 = Date.now();
  // A pool's history only grows with the chain's clock: one window from now, every pool created before now answers.
  const deadline = (await now()) + TWAP_WINDOW + 60;
  let left = await young();
  while (left.length > 0) {
    if ((await now()) > deadline) throw new Error(`no ${TWAP_WINDOW} s TWAP history yet on ${left.join(", ")}`);
    await new Promise((r) => setTimeout(r, 15_000));
    left = await young();
  }
  return `${pools.length} pools answer a ${TWAP_WINDOW} s TWAP; waited ${Math.round((Date.now() - t0) / 1000)} s`;
}

/** Aave governance v3's executor stand-in at the config's Aave DAO account, its owner the PayloadsController. */
async function placeExecutor(c: LocalChain, config: string): Promise<string> {
  const cfg = JSON.parse(readFileSync(config, "utf8")) as Record<string, any>;
  const dao = cfg.aaveLocal.aaveDao as string;
  const controller = cfg.aaveLocal.payloadsController as string;
  const art = JSON.parse(readFileSync(join(CONTRACTS, "out/AaveGovernanceExecutorStandIn.sol/AaveGovernanceExecutorStandIn.json"), "utf8"));
  await rpc(rpcUrl(c), "anvil_setCode", [dao, art.deployedBytecode.object]);
  await rpc(rpcUrl(c), "anvil_setStorageAt", [dao, "0x0", `0x${controller.slice(2).toLowerCase().padStart(64, "0")}`]);
  return `executor stand-in at ${dao}, owner ${controller}`;
}

/** Moves the clock (a timelock delay), mines, and publishes a fresh round on every feed, as Chainlink does. */
async function advance(c: LocalChain, seconds: number, env: NodeJS.ProcessEnv, log: string): Promise<string> {
  await rpc(rpcUrl(c), "evm_increaseTime", [seconds]);
  await rpc(rpcUrl(c), "evm_mine");
  refreshFeeds(c, env, log);
  return `+${seconds} s`;
}

/** One fresh round on every world feed (contracts/script/e2e/refresh-feeds.ts), at the current answers or `prices`. */
export function refreshFeeds(c: LocalChain, env: NodeJS.ProcessEnv, log: string, prices: Record<string, bigint> = {}): void {
  const args = ["script/e2e/refresh-feeds.ts", "--network", c.network];
  for (const [s, p] of Object.entries(prices)) args.push("--price", `${s}=${p}`);
  const r = spawnSync(process.execPath, args, { cwd: CONTRACTS, env, encoding: "utf8" });
  writeFileSync(log, redact(`${r.stdout ?? ""}${r.stderr ?? ""}`), { flag: "a" });
  if (r.status !== 0) throw new Error(`refresh-feeds failed: see ${log}`);
}

/** Produces the release manifest from the chain, verifies it against the chain and writes its contract table. */
function manifest(c: LocalChain, env: NodeJS.ProcessEnv, log: string): string {
  const cli = join(REPO, "packages/protocol/src/manifest/cli.ts");
  const out = join(outDir(c), "manifest.json");
  const run = (args: string[]) => {
    const r = spawnSync(process.execPath, [cli, ...args], { cwd: join(REPO, "packages/protocol"), env: { ...env, RPC_STACK: rpcUrl(c) }, encoding: "utf8", maxBuffer: 1 << 26 });
    writeFileSync(log, redact(`${r.stdout ?? ""}${r.stderr ?? ""}`), { flag: "a" });
    if (r.status !== 0) throw new Error(`manifest ${args[0]}: see ${log}: ${redact(r.stdout + r.stderr).trim().split(/\r?\n/).slice(-2).join(" ")}`);
    return r.stdout.trim().split(/\r?\n/).at(-1) ?? "";
  };
  run(["produce", "--network", c.network, "--rpc-env", "RPC_STACK", "--out", out]);
  const verified = run(["verify", "--manifest", out, "--rpc-env", "RPC_STACK"]);
  run(["table", "--manifest", out, "--out", join(outDir(c), "CONTRACTS.md")]);
  return verified;
}

/**
 * The timelock delays a chain's release waits, in seconds: the config's normal delay and the timelock's short delay (60 s
 * on a test network, REQ-ACCESS-187). The local chains keep the production delays (432,000 s and 43,200 s), the
 * rehearsal's, whose step names their ledgers hold.
 */
export function releaseDelays(c: LocalChain, config?: string): { normal: number; short: number } {
  if (!c.testnet) return { normal: 432_000, short: 43_200 };
  const cfg = JSON.parse(readFileSync(config ?? currentConfig(c), "utf8")) as { parameters: { timelockNormalDelay: number } };
  return { normal: Number(cfg.parameters.timelockNormalDelay), short: 60 };
}

/** The deploy steps of the first release, in order (the rehearsal's deploy step, contracts/script/e2e/e2e-local.sh). On
 * a test network the executor stand-in is deployed before Aave V4, which makes it admin. */
export function firstRelease(c: LocalChain, d = releaseDelays(c)): string[] {
  const head = c.testnet ? ["multicall3", "00-factories", "place-executor", "01-aave-v4"] : ["multicall3", "00-factories", "01-aave-v4", "place-executor"];
  return [
    ...head, "02-test-world", "03-avana", "04-access-operations", `advance:${d.normal + 1}`, "05-execute-access-operations",
    "06-aave-deployment-aip", "07-deploy-first-loss-reserves", "08-aave-loss-layers-aip", "07-fund-first-loss-reserves",
    ...listingSetupSteps(d), "swap-contracts", "manifest", "treasury",
  ];
}

/** The steps of a later release: each acts only on what the config adds (the rehearsal's day-2 phase). */
export function laterRelease(c: LocalChain, d = releaseDelays(c)): string[] {
  return [
    "01-aave-v4", "04-access-operations", `advance:${d.normal + 1}`, "05-execute-access-operations", "06-aave-deployment-aip",
    "07-deploy-first-loss-reserves", "08-aave-loss-layers-aip", "07-fund-first-loss-reserves", ...listingSteps(d, c.testnet !== undefined), "manifest",
  ];
}

const LOCAL_DELAYS = { normal: 432_000, short: 43_200 };
/** The local chains' sequences. */
export const FIRST_RELEASE = firstRelease({ testnet: undefined } as LocalChain, LOCAL_DELAYS);
export const LATER_RELEASE = laterRelease({ testnet: undefined } as LocalChain, LOCAL_DELAYS);

/** The listing's setup: integrations, tokens, debt assets and Spokes, the debt oracles and the Aave debt reserves. */
function listingSetupSteps(d: { normal: number }) {
  return ["09-listing-setup", `advance:${d.normal + 1}`, "09-execute-listing-setup", "09-debt-oracles", "10-aave-debt-reserves-aip"];
}

/**
 * A listing: its setup, then the markets (metadata, listing operation, Aave side) and their activation. On a test
 * network the listing first waits for the pools' TWAP history (waitForTwapHistory).
 */
function listingSteps(d: { normal: number; short: number }, testnet = false) {
  return [
    ...listingSetupSteps(d),
    "09-market-metadata", ...(testnet ? ["twap-history"] : []), "09-listing-markets", `advance:${d.normal + 1}`, "09-execute-listing-markets", "10-aave-markets-aip",
    "09-listing-activate", `advance:${d.short + 1}`, "09-execute-listing-activate",
  ];
}

/**
 * The swap screen's contracts on the test world, listed in the manifest's `external` (world.json `external`, which the
 * manifest producer reads): each venue's SwapRouter (step 02 deploys them) and a QuoterV2 deployed here against the
 * venue's factory and WETH, signed by the deployer keystore. Names: group `uniswap-v3` UniswapV3SwapRouter and
 * UniswapV3QuoterV2; group `slipstream` SlipstreamSwapRouter and SlipstreamQuoterV2 (generation 0's factory). The swap
 * tokens are the `token` group step 02 already lists. A quoter already listed is kept. Also each venue's LP position
 * manager: UniswapV3PositionManager, UniswapV4PositionManager, SlipstreamPositionManager (and `.n` per generation n).
 */
async function swapContracts(c: LocalChain): Promise<string> {
  const worldPath = join(outDir(c), "world.json");
  const world = JSON.parse(readFileSync(worldPath, "utf8")) as Record<string, any>;
  world.external ??= {};
  const { wallet, client } = await deployerClients(c);
  const deploy = async (out: string, factory: `0x${string}`): Promise<`0x${string}`> => {
    const art = JSON.parse(readFileSync(join(CONTRACTS, out, "QuoterV2.sol", "QuoterV2.json"), "utf8")) as { abi: unknown[]; bytecode: { object: `0x${string}` } };
    const hash = await wallet.deployContract({ abi: art.abi, bytecode: art.bytecode.object, args: [factory, world.tokens.WETH], chain: null });
    const r = await client.waitForTransactionReceipt({ hash });
    if (r.status !== "success" || !r.contractAddress) throw new Error(`QuoterV2 from ${out} did not deploy`);
    const { encodeDeployData } = await import("viem");
    const { recordCreated } = await import("../../testnet/verify.ts");
    recordCreated(outDir(c), r.contractAddress, encodeDeployData({ abi: art.abi, bytecode: art.bytecode.object, args: [factory, world.tokens.WETH] }));
    return r.contractAddress;
  };
  const venues = [
    { group: "uniswap-v3", prefix: "UniswapV3", out: "out-univ3-periphery", factory: world.uniswapV3Factory, router: world.uniswapV3SwapRouter },
    { group: "slipstream", prefix: "Slipstream", out: "out-slipstream-v1", factory: world.slipstreamFactories?.[0], router: world.slipstreamSwapRouter },
  ];
  const done: string[] = [];
  for (const v of venues) {
    if (!v.factory || !v.router) continue;
    const g = (world.external[v.group] ??= {});
    g[`${v.prefix}SwapRouter`] ??= { address: v.router, standIn: false };
    g[`${v.prefix}QuoterV2`] ??= { address: await deploy(v.out, v.factory), standIn: false };
    done.push(`${v.prefix}QuoterV2 ${g[`${v.prefix}QuoterV2`].address}`);
  }
  // The LP position managers (the faucet's starting positions, the webapp's LP NFT reader): Slipstream's generation 0
  // is SlipstreamPositionManager, a later generation n SlipstreamPositionManager.n.
  const pm = (group: string, name: string, address: string | undefined) => {
    if (!address) return;
    (world.external[group] ??= {})[name] ??= { address, standIn: false };
    done.push(`${name} ${address}`);
  };
  pm("uniswap-v3", "UniswapV3PositionManager", world.uniswapV3PositionManager);
  pm("uniswap-v4", "UniswapV4PositionManager", world.uniswapV4PositionManager);
  ((world.slipstreamPositionManagers ?? []) as string[]).forEach((a, i) => pm("slipstream", i ? `SlipstreamPositionManager.${i}` : "SlipstreamPositionManager", a));
  writeFileSync(worldPath, `${JSON.stringify(world, null, 2)}\n`);
  return done.join(", ");
}

/**
 * The faucet and the activity funds hold every test token of the world: the deployer, the tokens' minter, mints
 * each the equivalent of $1T once, signing from its keystore.
 */
async function fundTreasuries(c: LocalChain): Promise<string> {
  const { createPublicClient, createWalletClient, http, parseAbi } = await import("viem");
  const { privateKeyToAccount } = await import("viem/accounts");
  const { decryptKeystore } = await import("../../../../services/keeper/src/adapters/localKeystore.ts");
  const { PASSWORD_FILE, keystorePath } = await import("./keys.ts");
  const account = privateKeyToAccount(await decryptKeystore(readFileSync(keystorePath("deployer"), "utf8"), readFileSync(PASSWORD_FILE, "utf8").trim()));
  const wallet = createWalletClient({ account, transport: http(rpcUrl(c)) });
  const client = createPublicClient({ transport: http(rpcUrl(c)) });
  const abi = parseAbi(["function mint(address to, uint256 amount)"]);
  const world = JSON.parse(readFileSync(join(outDir(c), "world.json"), "utf8")) as { tokens: Record<string, `0x${string}`> };
  const cfg = JSON.parse(readFileSync(currentConfig(c), "utf8")) as { world: { tokens: { symbol: string; decimals: number; price8: number | string; kind?: string }[] } };
  const a = addresses();
  let n = 0;
  for (const t of cfg.world.tokens) {
    if (t.kind || !world.tokens[t.symbol]) continue;
    const amount = (10n ** 12n * 10n ** 8n * 10n ** BigInt(t.decimals)) / BigInt(t.price8);
    for (const to of [a.faucet, a["activity-funds"]]) {
      const hash = await wallet.writeContract({ address: world.tokens[t.symbol]!, abi, functionName: "mint", args: [to, amount], chain: null });
      const r = await client.waitForTransactionReceipt({ hash });
      if (r.status !== "success") throw new Error(`mint ${t.symbol} to ${to} reverted`);
    }
    n++;
  }
  return `${n} tokens to the faucet ${a.faucet} and the activity funds ${a["activity-funds"]}`;
}

/**
 * The OP Stack GasPriceOracle predeploy, which the keeper reads for Base's L1 data fee. A fork has the real one; a fresh
 * local Base gets a stand-in that answers every call with 0 (no L1 data fee on a local node).
 */
export async function placeL1FeeOracle(c: LocalChain): Promise<string> {
  if (c.network !== "base") return "not Base";
  const address = "0x420000000000000000000000000000000000000F";
  const code = await rpc<string>(rpcUrl(c), "eth_getCode", [address, "latest"]);
  if (code !== "0x") return "already has code";
  // PUSH1 0 PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN: 32 zero bytes for any call.
  await rpc(rpcUrl(c), "anvil_setCode", [address, "0x600060005260206000f3"]);
  return "stand-in placed";
}

/** Funds the stack's signers with gas on the chain. */
export async function fundSigners(c: LocalChain): Promise<void> {
  for (const a of Object.values(addresses())) await rpc(rpcUrl(c), "anvil_setBalance", [a, "0x21E19E0C9BAB2400000"]);
}

/** Runs `steps` of `release` in order, stopping at the first failure; the node and services keep running. */
export async function runRelease(c: LocalChain, release: string, steps: readonly string[], config: string, onStep?: (o: StepOutcome) => void): Promise<StepOutcome[]> {
  setConfig(c, config);
  const done: StepOutcome[] = [];
  const seen = new Map<string, number>();
  for (const s of steps) {
    const n = (seen.get(s) ?? 0) + 1;
    seen.set(s, n);
    const o = await runStep(c, release, s, config, n === 1 ? s : `${s}#${n}`);
    done.push(o);
    onStep?.(o);
    if (o.outcome === "fail") break;
  }
  return done;
}
