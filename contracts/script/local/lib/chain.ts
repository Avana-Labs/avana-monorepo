// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One local chain of the stack: its anvil node, the deploy and release steps run through script/deploy/step.sh, each
// recorded in deployments-local/<network>/stack-status.json, and the release manifest. A step that passed is never run
// again; a step that failed is run again (with forge's --start-fresh) by the next call, on the same node: the fix of a
// failed step costs that step, not a redeploy.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { CONTRACTS, type LocalChain, REPO, genesisTimestamp, outDir, rpcUrl } from "./env.ts";
import { addresses, signerEnv } from "./keys.ts";
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
const statePath = (c: LocalChain) => join(outDir(c), "anvil-state.hex");

/**
 * Starts the chain's anvil node unless one answers on its port: its chain ID, the rehearsal's code-size and gas limits,
 * every sender unlocked for the governance stand-ins, and an optional fork. It starts mining a block per transaction
 * (deploys and releases are not paced by the block time); `setMining(c, "interval")` then mines one block every
 * `blockTime` seconds, as the chain does. A state saved by `stopNode` is loaded back.
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
  const restore = existsSync(statePath(c));
  if (c.fork) {
    await startForkProxy(c);
    args.push("--fork-url", `http://127.0.0.1:${c.fork.proxyPort}`, "--fork-block-number", String(c.fork.block), "--retries", "10", "--fork-retry-backoff", "2000", "--timeout", "60000");
  } else if (!restore) args.push("--timestamp", String(genesisTimestamp()));
  start(nodeName(c), "anvil", args);
  await waitFor(`${c.label} node`, () => answers(c), 30_000, 300);
  if (restore) {
    await rpc(rpcUrl(c), "anvil_loadState", [readFileSync(statePath(c), "utf8").trim()]);
    return "restored";
  }
  return "started";
}

/** The chain's fork proxy, holding the network's RPC endpoints (environment or encrypted secrets) in its environment. */
async function startForkProxy(c: LocalChain): Promise<void> {
  const name = `fork-proxy-${c.key}`;
  if (running(name)) return;
  const { secretValue } = await import("./secrets.ts");
  const varName = `${c.network.toUpperCase()}_FORK_RPC_URL` as "ETHEREUM_FORK_RPC_URL" | "BASE_FORK_RPC_URL";
  const urls = secretValue(varName);
  if (!urls) throw new Error(`fork mode needs ${varName}: set it in the environment, or store it encrypted with \`node script/local/stack.ts secrets\``);
  start(name, process.execPath, [join(CONTRACTS, "script/local/fork-proxy.ts"), String(c.fork!.proxyPort)], { env: { FORK_UPSTREAMS: urls } });
  await waitFor(`${c.label} fork proxy`, async () => (await fetch(`http://127.0.0.1:${c.fork!.proxyPort}`)).ok, 15_000, 300);
}

/** Saves the node's state (anvil_dumpState) and stops it. */
export async function stopNode(c: LocalChain, save = true): Promise<void> {
  if (save && (await answers(c))) {
    const hex = await rpc<string>(rpcUrl(c), "anvil_dumpState");
    writeFileSync(statePath(c), hex);
  }
  stop(nodeName(c));
  stop(`fork-proxy-${c.key}`);
}

export const nodeRunning = (c: LocalChain) => running(nodeName(c));

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
 * parameters; the values the DAO sets (caps, credit lines, First-Loss Reserve and offset amounts, speed limits) come
 * from test-values.json. The stack's keystores fill every role: the deployer is also the test tokens' minter and the
 * First-Loss Reserves' funder, the keeper is the keeper and the operator helper's signer, the treasury is the fee
 * recipient.
 */
export function writeBaseConfig(c: LocalChain): string {
  const src = JSON.parse(readFileSync(join(CONTRACTS, "script/deploy/config/anvil.json"), "utf8")) as Record<string, any>;
  const a = addresses();
  const tv = testValues();
  const label = c.network;
  const lend = `lend${label.charAt(0).toUpperCase()}${label.slice(1)}`;
  const cfg = structuredClone(src);
  cfg.network = c.network;
  cfg.chainId = c.chainId;
  cfg.chain.blockTime = c.blockTime;
  // The MarketRegistry's MAX_MARKET_COUNT is fixed at deployment: room for every Hub file the stack may add.
  cfg.parameters.maxMarketCount = Number(process.env.STACK_MAX_MARKETS ?? 128);
  cfg.parameters.globals.feeRecipient = a.treasury;
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
  cfg.listing.creditLineWhole = tv.creditLineWhole;
  cfg.listing.speedLimits = tv.speedLimits;
  cfg.listing.spokes = [];
  cfg.listing.debtReserves = [];
  // A listing debt asset (its DebtOracle or fixed price, its rounding allowance) needs a CDP Spoke to price it: the Hub
  // file that makes the asset borrowable lists it, with the Spoke (planHub, from the test values).
  cfg.listing.debtAssets = [];
  // The protocol's market parameters a Hub file's market starts from, per integration (1 Uniswap v3, 2 Slipstream),
  // taken from the anvil config's first market of each; the market list itself starts empty.
  const template = (id: number) => {
    const { name: _n, spoke: _s, pool: _p, routes: _r, content: _c, ...rest } = (src.listing.markets as Record<string, any>[]).find((m) => m.integrationId === id)!;
    return rest;
  };
  cfg.listing.marketDefaults = { "1": template(1), "2": template(2) };
  cfg.listing.markets = [];
  cfg.listing.pools = {};
  for (const t of cfg.listing.tokens) {
    t.hubs = [label];
    Object.assign(t, tv.tokens?.default ?? {}, tv.tokens?.[t.symbol] ?? {});
  }
  // The chain's Hub files may need tokens and pools the test world lacks: script/deploy/hubs/<network>/world.json
  // adds them to the world step 02 deploys (an entry already in the world is kept as it is).
  const extra = join(CONTRACTS, "script/deploy/hubs", c.network, "world.json");
  if (existsSync(extra)) {
    const w = JSON.parse(readFileSync(extra, "utf8")) as Record<string, { symbol?: string; name?: string }[]>;
    for (const k of ["tokens", "uniswapPools", "slipstreamPools"]) {
      const have = new Set((cfg.world[k] as { symbol?: string; name?: string }[]).map((x) => x.symbol ?? x.name));
      for (const x of w[k] ?? []) if (!have.has(x.symbol ?? x.name)) cfg.world[k].push(x);
    }
  }
  const dst = join(outDir(c), "config-base.json");
  mkdirSync(outDir(c), { recursive: true });
  writeFileSync(dst, `${JSON.stringify(cfg, null, 2)}\n`);
  return dst;
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
    RPC_ANVIL: rpcUrl(c),
    [`RPC_${c.envSuffix}`]: rpcUrl(c),
    ...signerEnv(),
  };
}

/**
 * A step of the chain's release `release`: a named step of script/deploy/step.sh, `changes:<file>` (11-changes with a
 * changes file of deployments-local/<network>), or one of the stack's own (`multicall3`, `place-executor`,
 * `advance:<seconds>`, `manifest`, `treasury`). Passed steps are skipped.
 */
export async function runStep(c: LocalChain, release: string, step: string, config = currentConfig(c)): Promise<StepOutcome> {
  const key = `${release}:${step}`;
  const status = readStatus(c);
  const prev = status.steps[key];
  if (prev?.outcome === "pass") return { chain: c.network, step: key, outcome: "skipped", detail: prev.detail };
  const log = logPath(`${c.key}.${release}.${step.replace(/[:/]/g, "-")}`);
  mkdirSync(join(log, ".."), { recursive: true });
  const t0 = Date.now();
  let ok = false;
  let detail = "";
  const env = { ...process.env, ...stepEnv(c, config) };
  try {
    if (step === "multicall3") detail = await placeMulticall3(c);
    else if (step === "place-executor") detail = await placeExecutor(c, config);
    else if (step.startsWith("advance:")) detail = await advance(c, Number(step.slice(8)), env, log);
    else if (step === "manifest") detail = manifest(c, env, log);
    else if (step === "treasury") detail = await fundTreasuries(c);
    else if (step === "swap-contracts") detail = await swapContracts(c);
    else if (step.startsWith("changes:")) detail = runShell("11-changes", env, log, false, [join(outDir(c), step.slice(8))]);
    else detail = runShell(step, env, log, prev?.outcome === "fail");
    ok = true;
  } catch (e) {
    detail = (e as Error).message;
  }
  const s = readStatus(c);
  s.steps[key] = { outcome: ok ? "pass" : "fail", detail: detail.slice(0, 600), at: new Date().toISOString(), seconds: Math.round((Date.now() - t0) / 1000) };
  writeStatus(c, s);
  return { chain: c.network, step: key, outcome: ok ? "pass" : "fail", detail, log };
}

function runShell(step: string, env: NodeJS.ProcessEnv, log: string, fresh: boolean, args: string[] = []): string {
  // A step whose earlier broadcast stopped part-way is run again from the start, its old broadcast record archived.
  const e = { ...env, AVANA_FORGE_FLAGS: fresh ? "--start-fresh" : "" };
  const r = spawnSync(bash(), ["script/deploy/step.sh", step, ...args], { cwd: CONTRACTS, env: e, encoding: "utf8", maxBuffer: 1 << 28 });
  const text = `${r.stdout ?? ""}${r.stderr ?? ""}`;
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
  writeFileSync(log, `${r.stdout ?? ""}${r.stderr ?? ""}`, { flag: "a" });
  if (r.status !== 0) throw new Error(`refresh-feeds failed: see ${log}`);
}

/** Produces the release manifest from the chain, verifies it against the chain and writes its contract table. */
function manifest(c: LocalChain, env: NodeJS.ProcessEnv, log: string): string {
  const cli = join(REPO, "packages/protocol/src/manifest/cli.ts");
  const out = join(outDir(c), "manifest.json");
  const run = (args: string[]) => {
    const r = spawnSync(process.execPath, [cli, ...args], { cwd: join(REPO, "packages/protocol"), env: { ...env, RPC_STACK: rpcUrl(c) }, encoding: "utf8", maxBuffer: 1 << 26 });
    writeFileSync(log, `${r.stdout ?? ""}${r.stderr ?? ""}`, { flag: "a" });
    if (r.status !== 0) throw new Error(`manifest ${args[0]}: see ${log}: ${(r.stdout + r.stderr).trim().split(/\r?\n/).slice(-2).join(" ")}`);
    return r.stdout.trim().split(/\r?\n/).at(-1) ?? "";
  };
  run(["produce", "--network", c.network, "--rpc-env", "RPC_STACK", "--out", out]);
  const verified = run(["verify", "--manifest", out, "--rpc-env", "RPC_STACK"]);
  run(["table", "--manifest", out, "--out", join(outDir(c), "CONTRACTS.md")]);
  return verified;
}

/** The deploy steps of the first release, in order (the rehearsal's deploy step, contracts/script/e2e/e2e-local.sh). */
export const FIRST_RELEASE = [
  "multicall3", "00-factories", "01-aave-v4", "place-executor", "02-test-world", "03-avana", "04-access-operations",
  "advance:432001", "05-execute-access-operations", "06-aave-deployment-aip", "07-deploy-first-loss-reserves",
  "08-aave-loss-layers-aip", "07-fund-first-loss-reserves", ...listingSetupSteps(), "swap-contracts", "manifest", "treasury",
];

/** The steps of a later release: each acts only on what the config adds (the rehearsal's day-2 phase). */
export const LATER_RELEASE = [
  "01-aave-v4", "04-access-operations", "advance:432001", "05-execute-access-operations", "06-aave-deployment-aip",
  "07-deploy-first-loss-reserves", "08-aave-loss-layers-aip", "07-fund-first-loss-reserves", ...listingSteps(), "manifest",
];

/** The listing's setup: integrations, tokens, debt assets and Spokes, the debt oracles and the Aave debt reserves. */
function listingSetupSteps() {
  return ["09-listing-setup", "advance:432001", "09-execute-listing-setup", "09-debt-oracles", "10-aave-debt-reserves-aip"];
}

/** A listing: its setup, then the markets (metadata, listing operation, Aave side) and their activation. */
function listingSteps() {
  return [
    ...listingSetupSteps(),
    "09-market-metadata", "09-listing-markets", "advance:432001", "09-execute-listing-markets", "10-aave-markets-aip",
    "09-listing-activate", "advance:43201", "09-execute-listing-activate",
  ];
}

/**
 * The swap screen's contracts on the test world, listed in the manifest's `external` (world.json `external`, which the
 * manifest producer reads): each venue's SwapRouter (step 02 deploys them) and a QuoterV2 deployed here against the
 * venue's factory and WETH, signed by the deployer keystore. Names: group `uniswap-v3` UniswapV3SwapRouter and
 * UniswapV3QuoterV2; group `slipstream` SlipstreamSwapRouter and SlipstreamQuoterV2 (generation 0's factory). The swap
 * tokens are the `token` group step 02 already lists. A quoter already listed is kept.
 */
async function swapContracts(c: LocalChain): Promise<string> {
  const { createPublicClient, createWalletClient, http } = await import("viem");
  const { privateKeyToAccount } = await import("viem/accounts");
  const { PASSWORD_FILE, keystorePath } = await import("./keys.ts");
  const { decryptKeystore } = await import("../../../../services/keeper/src/adapters/localKeystore.ts");
  const worldPath = join(outDir(c), "world.json");
  const world = JSON.parse(readFileSync(worldPath, "utf8")) as Record<string, any>;
  world.external ??= {};
  const account = privateKeyToAccount(await decryptKeystore(readFileSync(keystorePath("deployer"), "utf8"), readFileSync(PASSWORD_FILE, "utf8").trim()));
  const wallet = createWalletClient({ account, transport: http(rpcUrl(c)) });
  const client = createPublicClient({ transport: http(rpcUrl(c)) });
  const deploy = async (out: string, factory: `0x${string}`): Promise<`0x${string}`> => {
    const art = JSON.parse(readFileSync(join(CONTRACTS, out, "QuoterV2.sol", "QuoterV2.json"), "utf8")) as { abi: unknown[]; bytecode: { object: `0x${string}` } };
    const hash = await wallet.deployContract({ abi: art.abi, bytecode: art.bytecode.object, args: [factory, world.tokens.WETH], chain: null });
    const r = await client.waitForTransactionReceipt({ hash });
    if (r.status !== "success" || !r.contractAddress) throw new Error(`QuoterV2 from ${out} did not deploy`);
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
  for (const s of steps) {
    const o = await runStep(c, release, s, config);
    done.push(o);
    onStep?.(o);
    if (o.outcome === "fail") break;
  }
  return done;
}
