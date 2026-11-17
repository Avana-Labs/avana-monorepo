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

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { CONTRACTS, type LocalChain, TESTNETS, chainOf, outDir, rpcUrl } from "../local/lib/env.ts";
import { type StepOutcome, currentConfig, executorStandIn, firstRelease, readStatus, redact, rpc, runRelease, stepEnv, writeBaseConfig } from "../local/lib/chain.ts";
import { FUNDED_ROLES, SIGNER_ROLES, type TestnetRoles, testnetRoles } from "./keys.ts";

/** The timelock's normal delay on a test network, seconds (its floor there is 60 s, REQ-ACCESS-187). */
export const NORMAL_DELAY = 120;
/** One timelock operation's execution gas budget on a test network: under the 2^24 per-transaction cap (EIP-7825). */
export const OPERATION_GAS_BUDGET = 15_000_000;
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

/** The chain's RPC URL and the explorer key: the environment, else the encrypted secrets of `stack.ts secrets`. */
async function loadSecrets(c: LocalChain): Promise<void> {
  const { secretValue } = await import("../local/lib/secrets.ts");
  for (const n of [c.testnet!.rpcEnv, "ETHERSCAN_API_KEY"] as const) {
    if (!process.env[n]) {
      const v = secretValue(n as "SEPOLIA_RPC_URL");
      if (v) process.env[n] = v;
    }
  }
  if (!process.env[c.testnet!.rpcEnv]) throw new Stop(`${c.testnet!.rpcEnv} is not set, in the environment or the encrypted secrets store`);
  const id = Number(BigInt(await rpc<string>(rpcUrl(c), "eth_chainId")));
  if (id !== c.chainId) throw new Stop(`${c.testnet!.rpcEnv} answers chain ${id}, not ${c.label} test network ${c.chainId}`);
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
export async function testnetConfig(c: LocalChain, rel: string): Promise<string> {
  const roles = testnetRoles();
  const executor = (await executorStandIn(roles.signers.payloadsController)).address;
  const path = writeBaseConfig(c, baseRoles(roles), testnetPatch(roles, executor, rel));
  const text = readFileSync(path, "utf8").toLowerCase();
  const left = ANVIL_ACCOUNTS.filter((x) => text.includes(x.slice(2)));
  if (left.length) throw new Error(`the config still names anvil accounts ${left.join(", ")}: every role must be a test-network account`);
  return path;
}

/** The base config's four roles on a test network. */
export const baseRoles = ({ signers: s, addresses: a }: TestnetRoles) => ({ deployer: s.deployer, keeper: a.KEEPER, treasury: a.TREASURY, guardian: a.AAVE_PROTOCOL_GUARDIAN });

/**
 * What a test network's config changes in the local stack's: its roles, release, normal delay and operation gas budget,
 * and nothing else. testnet.test.ts checks every other value against the local stack's config, built from the same
 * test values (script/local/test-values.json, the one source of the market parameters).
 */
export function testnetPatch({ signers: s, addresses: a }: TestnetRoles, executor: string, rel: string) {
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
    // The gas vault is not part of the deploy (as on the local stack); its signer would be the keeper.
    cfg.gasVault.signers = cfg.gasVault.signers.slice(0, 1).map((g: Record<string, unknown>) => ({ ...g, signer: a.KEEPER }));
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
  if (process.env.ETHERSCAN_API_KEY && !flag("no-verify")) process.env.AVANA_VERIFY = "1";
  const b = await balances(c);
  const empty = FUNDED_ROLES.filter((k) => b[k] === 0n);
  if (empty.length) throw new Stop(`no test ETH on the ${empty.join(", ")} signer${empty.length > 1 ? "s" : ""} (see \`roles\`)`);
  const status = readStatus(c);
  const config = status.config ? currentConfig(c) : await testnetConfig(c, rel);
  say(`${c.network} (${c.chainId}): release ${rel}, config ${config}${process.env.AVANA_VERIFY ? ", verifying on the explorer" : ""}`);
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
  say(`${c.network}: deployed; manifest ${join(outDir(c), "manifest.json")}. Keep the feeds fresh: node script/testnet/testnet.ts feeds --chain ${c.network}`);
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
      default:
        say("usage: node script/testnet/testnet.ts roles | deploy --chain <sepolia|base-sepolia> [--no-verify] | status --chain <c> | feeds --chain <c> [--every <s>]");
        process.exitCode = 2;
    }
  } catch (e) {
    say(e instanceof Stop ? `STOPPED ${e.message}` : `FAILED ${(e as Error).stack ?? e}`);
    process.exitCode = 1;
  }
}

if (process.argv[1]?.endsWith("testnet.ts")) await main();
