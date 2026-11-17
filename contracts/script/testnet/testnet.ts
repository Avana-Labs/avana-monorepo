// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The public test networks (Sepolia, Base Sepolia), deployed exactly as the local stack deploys its chains: the same
// base config (env.ts, chain.ts baseConfig: one tier-3 Hub per chain, the anvil config's protocol parameters, the test
// values, the chain's world.json), the same step sequence (step.sh through chain.ts runRelease) and the same Hub files,
// released in name order (script/deploy/hubs/<ethereum|base>/). What differs is only what a public chain needs
// (testnetPatch): every signer is an encrypted keystore (keys.ts), including the stand-ins for the governance Safe, the
// Aave PayloadsController and the OCR2 oracles, so the timelock operations and the Aave AIPs run by real transactions;
// the executor stand-in is deployed by a transaction before Aave V4; each timelock delay is waited on the chain's clock
// (60 s floors, REQ-ACCESS-187); the release is a tag at HEAD; each step's contracts are verified on the explorer.
// A step that passed is never run again: rerun `deploy` after any failure.
//
// Commands: roles | deploy --chain <sepolia|base-sepolia> [--no-verify] | status --chain <c> | feeds --chain <c> [--every <s>]
//   | verify --chain <c> [--dry-run]   the explorer verification alone, for a retry (verify.ts)

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { CONTRACTS, type LocalChain, TESTNETS, chainOf, outDir, rpcUrl } from "../local/lib/env.ts";
import { type Status, type StepOutcome, currentConfig, executorStandIn, firstRelease, forgeDirs, readStatus, redact, rpc, runRelease, stepEnv, writeBaseConfig } from "../local/lib/chain.ts";
import { verifyRelease } from "./verify.ts";
import { FUNDED_ROLES, SIGNER_ROLES, type TestnetRoles, configFile, testnetRoles } from "./keys.ts";
import { rpcSummary, useHealthyRpc } from "./rpc.ts";

/** The timelock's normal delay on a test network, seconds (its floor there is 60 s, REQ-ACCESS-187). */
export const NORMAL_DELAY = 120;
/** One timelock operation's execution gas budget on a test network: under the 2^24 per-transaction cap (EIP-7825). */
export const OPERATION_GAS_BUDGET = 15_000_000;
/** A test network's AvanaGasVault: the deployer funds it with `fundWei` (0.5 test ETH), unless the private config
 * file sets the chain's GAS_VAULT_FUND_WEI_<chain> (gasVaultFundWei). */
export const GAS_VAULT = { fundWei: "500000000000000000" };

/** The private config file's key for the chain's gas vault funding, in wei: GAS_VAULT_FUND_WEI_SEPOLIA, …_BASE_SEPOLIA. */
export const gasVaultFundKey = (c: LocalChain) => `GAS_VAULT_FUND_WEI_${c.envSuffix}`;

/**
 * The wei the deployer funds the chain's gas vault with: the private file's GAS_VAULT_FUND_WEI_<chain>, a whole number
 * from 0 to 0.5 ETH, else 0.5 ETH. At 0 the vault is deployed and its signer added, but 12-fund-gas-vault sends nothing
 * (the script funds only up to fundWei); anyone can fund it later with the vault's `fund`.
 */
export function gasVaultFundWei(c: LocalChain, file: Record<string, string | undefined>): string {
  const key = gasVaultFundKey(c);
  const v = file[key]?.trim();
  if (!v) return GAS_VAULT.fundWei;
  if (!/^\d+$/.test(v)) throw new Error(`${key}: "${v}" is not a whole number of wei`);
  if (BigInt(v) > BigInt(GAS_VAULT.fundWei)) throw new Error(`${key}: ${v} wei is more than ${GAS_VAULT.fundWei} (0.5 ETH)`);
  return BigInt(v).toString();
}

/**
 * On a rerun, the config was written by an earlier run: its gas vault funding is brought to `fundWei` while the release
 * has not funded the vault yet, so a changed GAS_VAULT_FUND_WEI_<chain> applies. Returns whether the file changed.
 */
export function syncGasVaultFund(configPath: string, fundWei: string): boolean {
  const cfg = JSON.parse(readFileSync(configPath, "utf8")) as Record<string, any>;
  if (!cfg.gasVault || cfg.gasVault.fundWei === fundWei) return false;
  cfg.gasVault.fundWei = fundWei;
  writeFileSync(configPath, `${JSON.stringify(cfg, null, 2)}\n`);
  return true;
}
/**
 * The dollars each native-ETH Uniswap v4 pool of the world (an `a` or `b` of `ETH`) is seeded with on a test network.
 * Step 02 pays half of a pool's `usd` in the deployer's own ETH (the other side, and the reference pool, are mintable
 * test tokens): the local stack's $2,000,000 and $1,000,000 would take hundreds of test ETH. No Hub file lists these
 * pools, so they only need to exist; $10 each takes about 0.0017 ETH at the world's $3,000 ETH.
 */
export const NATIVE_V4_POOL_USD = 10;

/** Whether a world Uniswap v4 pool holds native ETH. */
export const isNativeV4Pool = (p: { a?: string; b?: string }) => p.a === "ETH" || p.b === "ETH";

/** Sets each native-ETH Uniswap v4 pool's `usd` to NATIVE_V4_POOL_USD; returns the names of the pools it changed. */
export function shrinkNativeV4Pools(cfg: Record<string, any>): string[] {
  const changed: string[] = [];
  for (const p of (cfg.world?.uniswapV4Pools ?? []) as Record<string, any>[]) {
    if (!isNativeV4Pool(p) || p.usd === NATIVE_V4_POOL_USD) continue;
    p.usd = NATIVE_V4_POOL_USD;
    changed.push(p.name);
  }
  return changed;
}

/**
 * The wei of ETH the deployer pays into the config's native-ETH Uniswap v4 pools, as step 02 computes it
 * (02_DeployWorld `_uniswapV4Pool`: `_amountForUsd(ETH, usd / 2)`, ETH priced at the WETH token's `price8`).
 */
export function nativeV4PoolWei(cfg: Record<string, any>): bigint {
  const weth = ((cfg.world?.tokens ?? []) as Record<string, any>[]).find((t) => t.symbol === "WETH");
  let wei = 0n;
  for (const p of (cfg.world?.uniswapV4Pools ?? []) as Record<string, any>[]) {
    if (!isNativeV4Pool(p)) continue;
    if (!weth) throw new Error(`world.uniswapV4Pools ${p.name}: no WETH token to price ETH`);
    wei += (BigInt(p.usd) / 2n) * 10n ** 8n * 10n ** 18n / BigInt(weth.price8);
  }
  return wei;
}

/** The first release's step that deploys the world, its native-ETH Uniswap v4 pools among it. */
export const WORLD_STEP = "first:02-test-world";

/**
 * On a rerun, the config was written by an earlier run (`status.config`): while the world step has not passed, its
 * native-ETH Uniswap v4 pools are brought to NATIVE_V4_POOL_USD (shrinkNativeV4Pools); once it has, the config is the
 * world's record and is left as it is. No step before it reads the pools. Returns the names of the pools it changed.
 */
export function syncNativeV4Pools(configPath: string, status: Pick<Status, "config" | "steps">): string[] {
  if (!status.config || status.steps[WORLD_STEP]?.outcome === "pass") return [];
  const cfg = JSON.parse(readFileSync(configPath, "utf8")) as Record<string, any>;
  const changed = shrinkNativeV4Pools(cfg);
  if (changed.length) writeFileSync(configPath, `${JSON.stringify(cfg, null, 2)}\n`);
  return changed;
}

/** Its one keeper signer: refilled below 0.05 ETH to 0.2 ETH, at most 0.2 ETH a day. */
export const GAS_VAULT_SIGNER = { minBalanceWei: "50000000000000000", targetBalanceWei: "200000000000000000", periodCapWei: "200000000000000000" };
/** A directory the rehearsal (rehearse.ts) wrote: a real deploy refuses to resume it. */
export const REHEARSAL_MARK = ".rehearsal";

/** The anvil default accounts: none may stay in a test network's config. */
const ANVIL_ACCOUNTS = [
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
  "0x90F79bf6EB2c4f870365E785982E1f101E93b906", "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65", "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc",
  "0x976EA74026E726554dB657fA54763abd0C3a0aa9", "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955", "0x23618e81E3F5cdF7f54C3d65f7FBc0aBf5B21E8f",
  "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720", "0xBcd4042DE499D14e55001CcbB24a551F3b954096",
].map((a) => a.toLowerCase());

const argv = process.argv.slice(2);
const opt = (n: string) => {
  const i = argv.indexOf(`--${n}`);
  return i === -1 ? undefined : argv[i + 1];
};
const flag = (n: string) => argv.includes(`--${n}`);
const say = (s: string) => process.stdout.write(`${redact(s)}\n`);
class Stop extends Error {}

function testnet(): LocalChain {
  const name = opt("chain");
  if (!name) throw new Stop(`--chain is required: ${TESTNETS.map((c) => c.network).join(" or ")}`);
  const c = chainOf(name);
  if (!c.testnet) throw new Stop(`${name} is not a test network: ${TESTNETS.map((x) => x.network).join(", ")}`);
  return c;
}

/**
 * The chain's RPC and the explorer key. The RPC is the healthiest of the providers whose credentials are set
 * (ALCHEMY_API_KEY; QUICKNODE_ENDPOINT_NAME and QUICKNODE_TOKEN for the backup), or the explicit endpoint
 * (SEPOLIA_RPC_URL, BASE_SEPOLIA_RPC_URL) when one is set (rpc.ts); each comes from the environment, else the
 * encrypted secrets of `stack.ts secrets`. Each step picks its provider again (chain.ts runStep).
 */
async function loadSecrets(c: LocalChain): Promise<void> {
  const { secretValue } = await import("../local/lib/secrets.ts");
  if (!process.env.ETHERSCAN_API_KEY) {
    const v = secretValue("ETHERSCAN_API_KEY");
    if (v) process.env.ETHERSCAN_API_KEY = v;
  }
  try {
    await useHealthyRpc(c);
  } catch (e) {
    throw new Stop(`${c.network} RPC: ${(e as Error).message}`);
  }
  const id = Number(BigInt(await rpc<string>(rpcUrl(c), "eth_chainId")));
  if (id !== c.chainId) throw new Stop(`the ${c.network} RPC answers chain ${id}, not ${c.label} test network ${c.chainId}`);
  say(`${c.network}: RPC ${await rpcSummary(c)}`);
}

/** AVANA_RELEASE, a tag at HEAD (the scripts check it again, with the deployed sources clean). */
function release(): string {
  const r = process.env.AVANA_RELEASE;
  if (!r) throw new Stop("set AVANA_RELEASE to the release tag checked out");
  const tags = spawnSync("git", ["tag", "--points-at", "HEAD"], { cwd: CONTRACTS, encoding: "utf8" }).stdout.split(/\r?\n/);
  if (!tags.includes(r)) throw new Stop(`HEAD is not the tag ${r}`);
  return r;
}

/** The chain's base config: the local stack's (writeBaseConfig), every role a test-network account (testnetPatch). */
export async function testnetConfig(c: LocalChain, rel: string, fundWei = GAS_VAULT.fundWei): Promise<string> {
  const roles = testnetRoles();
  const executor = (await executorStandIn(roles.signers.payloadsController)).address;
  const path = writeBaseConfig(c, baseRoles(roles), testnetPatch(roles, executor, rel, fundWei));
  const text = readFileSync(path, "utf8").toLowerCase();
  const left = ANVIL_ACCOUNTS.filter((x) => text.includes(x.slice(2)));
  if (left.length) throw new Error(`the config still names anvil accounts ${left.join(", ")}: every role must be a test-network account`);
  return path;
}

/** The base config's four roles on a test network. */
export const baseRoles = ({ signers: s, addresses: a }: TestnetRoles) => ({ deployer: s.deployer, keeper: a.KEEPER, treasury: a.TREASURY, guardian: a.AAVE_PROTOCOL_GUARDIAN });

/**
 * What a test network's config changes in the local stack's: its roles, release, normal delay and operation gas budget,
 * the gas vault, and the native-ETH Uniswap v4 pools' size (NATIVE_V4_POOL_USD), and nothing else. testnet.test.ts checks every other value against the local stack's config, built from the same
 * test values (script/local/test-values.json, the one source of the market parameters).
 */
export function testnetPatch({ signers: s, addresses: a }: TestnetRoles, executor: string, rel: string, fundWei = GAS_VAULT.fundWei) {
  return (cfg: Record<string, any>) => {
    cfg.release = rel;
    cfg.parameters.timelockNormalDelay = NORMAL_DELAY;
    cfg.chain.operationGasBudget = OPERATION_GAS_BUDGET;
    cfg.governance.governanceSafe = s.governance;
    cfg.governance.emergencyGuardian = a.EMERGENCY_GUARDIAN;
    cfg.governance.jointConfigSafe = a.JOINT_CONFIG_SAFE;
    cfg.governance.aaveGovernanceExecutor = executor;
    cfg.aaveLocal.aaveDao = executor;
    cfg.aaveLocal.payloadsController = s.payloadsController;
    cfg.aave.governanceExecutor = executor;
    for (const h of cfg.operatorHelpers) h.fundingSafe = s.governance;
    // The gas vault (first release, gasVaultSteps): one keeper signer, sized for test ETH. The deployer funds it with
    // `fundWei` (gasVaultFundWei; 0: not funded).
    cfg.gasVault = { ...cfg.gasVault, fundWei };
    cfg.gasVault.signers = [{ signer: a.KEEPER, ...GAS_VAULT_SIGNER }];
    // The native-ETH Uniswap v4 pools: seeded with the deployer's real test ETH, so a few dollars each.
    shrinkNativeV4Pools(cfg);
  };
}

async function balances(c: LocalChain): Promise<Record<string, bigint>> {
  const { signers } = testnetRoles();
  const out: Record<string, bigint> = {};
  for (const k of SIGNER_ROLES) out[k] = BigInt(await rpc<string>(rpcUrl(c), "eth_getBalance", [signers[k], "latest"]));
  return out;
}

const eth = (wei: bigint) => `${(Number(wei) / 1e18).toFixed(4)} ETH`;
const show = (o: StepOutcome) => {
  if (o.outcome !== "skipped") say(`  ${o.outcome.toUpperCase().padEnd(5)} ${o.chain} ${o.step}${o.outcome === "fail" ? `: ${o.detail}` : ""}`);
};

/** The whole deploy of one test network: the first release, then every Hub file not yet released, in name order. */
async function deploy(): Promise<void> {
  const c = testnet();
  await loadSecrets(c);
  const rel = release();
  if (existsSync(join(outDir(c), REHEARSAL_MARK)) && process.env.AVANA_REHEARSAL !== "1") {
    throw new Stop(`${outDir(c)} holds a rehearsal's outputs: move it away before the real deploy`);
  }
  process.env.AVANA_RELEASE = rel;
  if (!flag("no-verify") && !process.env.ETHERSCAN_API_KEY) throw new Stop("ETHERSCAN_API_KEY is not set, in the environment or the encrypted secrets store (or pass --no-verify)");
  const b = await balances(c);
  const empty = FUNDED_ROLES.filter((k) => b[k] === 0n);
  if (empty.length) throw new Stop(`no test ETH on the ${empty.join(", ")} signer${empty.length > 1 ? "s" : ""} (see \`roles\`)`);
  let fundWei: string;
  try {
    fundWei = gasVaultFundWei(c, configFile());
  } catch (e) {
    throw new Stop(`the test-network config file: ${(e as Error).message}`);
  }
  const status = readStatus(c);
  const config = status.config ? currentConfig(c) : await testnetConfig(c, rel, fundWei);
  say(`${c.network} (${c.chainId}): release ${rel}, config ${config}${flag("no-verify") ? "" : ", explorer verification at the end"}`);
  if (status.steps["first:12-fund-gas-vault"]?.outcome !== "pass") {
    if (status.config && syncGasVaultFund(config, fundWei)) say(`${c.network}: gas vault funding set to ${fundWei} wei (${gasVaultFundKey(c)})`);
    if (fundWei === "0") say(`${c.network}: gas vault not funded: ${gasVaultFundKey(c)} = 0; fund it later with its \`fund\``);
  }
  const shrunk = syncNativeV4Pools(config, status);
  if (shrunk.length) {
    const wei = nativeV4PoolWei(JSON.parse(readFileSync(config, "utf8")));
    say(`${c.network}: native-ETH Uniswap v4 pools ${shrunk.join(", ")} set to $${NATIVE_V4_POOL_USD} each (${eth(wei)} from the deployer in all)`);
  }
  const first = await runRelease(c, "first", firstRelease(c), config, show);
  const failed = first.find((o) => o.outcome === "fail");
  if (failed) throw new Stop(`${failed.step} failed (log ${failed.log}); fix it and run deploy again: passed steps are not rerun`);
  const { addHub, hubRelease } = await import("../local/operator/hub.ts");
  const dir = join(CONTRACTS, "script/deploy/hubs", c.hubs);
  for (const f of readdirSync(dir).filter((x) => x.endsWith(".json") && x !== "world.json").sort()) {
    if (readStatus(c).steps[`${hubRelease(f)}:manifest`]?.outcome === "pass") continue;
    say(`${c.network}: Hub file ${c.hubs}/${f}`);
    const r = await addHub({ chain: c.network, hubFile: join(dir, f) }, show);
    if (!r.ok) throw new Stop(`Hub file ${f}: ${r.error ?? r.steps.find((s) => s.outcome === "fail")?.detail}; fix it and run deploy again`);
    say(`${c.network}: ${f} released, ${r.markets?.length ?? 0} markets`);
  }
  say(`${c.network}: deployed; manifest ${join(outDir(c), "manifest.json")}`);
  // The last stage: every contract of the release verified on the explorer (verify.ts).
  if (!flag("no-verify")) await verifyStage(c, false);
}

/** The explorer verification of everything the chain's releases deployed; a rerun retries only what is left. */
async function verifyStage(c: LocalChain, dryRun: boolean): Promise<void> {
  say(`${c.network}: explorer verification${dryRun ? " (dry run: the commands only)" : ""}`);
  const env = forgeDirs(c);
  const r = await verifyRelease({ contracts: CONTRACTS, outDir: outDir(c), broadcastRoot: join(CONTRACTS, env.FOUNDRY_BROADCAST!), chainId: c.chainId, dryRun, say });
  say(`${c.network}: ${r.verified} verified, ${r.skipped} skipped, ${r.failed.length} failed`);
  for (const f of r.failed) say(`  ${f}`);
  if (r.failed.length) throw new Stop(`${r.failed.length} contracts are not verified yet: run verify --chain ${c.network} again`);
}

async function verify(): Promise<void> {
  const c = testnet();
  const dryRun = flag("dry-run");
  if (!dryRun) {
    const { secretValue } = await import("../local/lib/secrets.ts");
    if (!process.env.ETHERSCAN_API_KEY) {
      const v = secretValue("ETHERSCAN_API_KEY");
      if (v) process.env.ETHERSCAN_API_KEY = v;
    }
  }
  await verifyStage(c, dryRun);
}

async function status(): Promise<void> {
  const c = testnet();
  const s = readStatus(c);
  const steps = Object.entries(s.steps);
  say(`${c.network}: ${steps.filter(([, r]) => r.outcome === "pass").length} steps passed${steps.some(([, r]) => r.outcome === "fail") ? `, failed: ${steps.filter(([, r]) => r.outcome === "fail").map(([k]) => k).join(", ")}` : ""}; config ${s.config ?? "none yet"}`);
}

async function roles(): Promise<void> {
  const { signers, addresses } = testnetRoles();
  say("signers:");
  for (const k of SIGNER_ROLES) say(`  ${k.padEnd(20)} ${signers[k]}${(FUNDED_ROLES as readonly string[]).includes(k) ? "  (needs test ETH)" : ""}`);
  say("addresses:");
  for (const [k, v] of Object.entries(addresses)) say(`  ${k.padEnd(24)} ${v}`);
  for (const c of TESTNETS) {
    try {
      await loadSecrets(c);
    } catch (e) {
      say(`${c.network}: ${(e as Error).message}`);
      continue;
    }
    const b = await balances(c);
    say(`${c.network}: ${FUNDED_ROLES.map((k) => `${k} ${eth(b[k]!)}`).join(", ")}`);
  }
}

/** Publishes a round on every feed of the chain's world every `--every` seconds (default 3,600; heartbeat 86,400). */
async function feeds(): Promise<void> {
  const c = testnet();
  await loadSecrets(c);
  const every = Number(opt("every") ?? 3600);
  const env = { ...process.env, ...stepEnv(c) };
  say(`${c.network}: a round on every feed every ${every} s, signed by the oracles' keystores (Ctrl-C stops)`);
  const r = spawnSync(process.execPath, ["script/e2e/refresh-feeds.ts", "--network", c.network, "--every", String(every)], { cwd: CONTRACTS, env, stdio: "inherit" });
  process.exitCode = r.status ?? 1;
}

async function main() {
  try {
    switch (argv[0]) {
      case "deploy":
        await deploy();
        break;
      case "status":
        await status();
        break;
      case "roles":
        await roles();
        break;
      case "feeds":
        await feeds();
        break;
      case "verify":
        await verify();
        break;
      default:
        say("usage: node script/testnet/testnet.ts roles | deploy --chain <sepolia|base-sepolia> [--no-verify] | status --chain <c> | feeds --chain <c> [--every <s>] | verify --chain <c> [--dry-run]");
        process.exitCode = 2;
    }
  } catch (e) {
    say(e instanceof Stop ? `STOPPED ${e.message}` : `FAILED ${(e as Error).stack ?? e}`);
    process.exitCode = 1;
  }
}

if (process.argv[1]?.endsWith("testnet.ts")) await main();
