// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The test-network deploy rehearsed with no RPC: one anvil per test network with its real chain ID (11155111,
// 84532) and hardfork (Osaka: the EIP-7825 per-transaction gas cap, the EIP-170 code-size limit), nothing unlocked, and
// `testnet.ts deploy` run against it end to end, signed only by throwaway keystores made here in a temporary directory,
// with the private config file that names them. Only this harness touches the nodes' state, standing in for what the
// real networks already have (the Safe Singleton Factory and Multicall3 at their canonical addresses) and for the test
// ETH of the signers that send transactions. The nodes mine on a timer at the chain's block time and at every
// transaction (anvil --mixed-mining), so a timelock delay passes on the chain's clock. At the end each account's gas
// and ETH spent is read from the chain and written to gas-report.json in the run's directory.
//
// Arguments: [--chains sepolia,base-sepolia] [--dir <dir>] [--keep]; AVANA_RELEASE is a local tag at HEAD. Outputs go
// to deployments-local/<network>/, marked as a rehearsal's (a real deploy refuses to resume them).

import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CONTRACTS, type LocalChain, chainOf, outDir } from "../local/lib/env.ts";
import { FUNDED_ROLES } from "./keys.ts";

const argv = process.argv.slice(2);
const opt = (n: string) => {
  const i = argv.indexOf(`--${n}`);
  return i === -1 ? undefined : argv[i + 1];
};
const say = (s: string) => process.stdout.write(`${s}\n`);

const PORTS: Record<string, number> = { sepolia: Number(process.env.REHEARSAL_PORT_SEPOLIA ?? 8655), "base-sepolia": Number(process.env.REHEARSAL_PORT_BASE_SEPOLIA ?? 8656) };
const SAFE_SINGLETON_FACTORY = "0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7";
const SAFE_SINGLETON_FACTORY_CODE =
  "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";

async function rpc<T>(url: string, method: string, params: unknown[] = []): Promise<T> {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = (await r.json()) as { result?: T; error?: { message: string } };
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result as T;
}

function cast(args: string[], env: NodeJS.ProcessEnv = {}): string {
  const r = spawnSync("cast", args, { encoding: "utf8", env: { ...process.env, ...env } });
  if (r.status !== 0) throw new Error(`cast ${args.slice(0, 2).join(" ")}: ${(r.stderr || r.stdout).trim()}`);
  return r.stdout.trim();
}

/** Throwaway keystores, their shared password file and the private config file naming them; returns its path. */
function makeRoles(home: string): string {
  const ks = join(home, "keys");
  mkdirSync(ks, { recursive: true });
  const pw = join(home, "pass");
  if (!existsSync(pw)) writeFileSync(pw, randomBytes(32).toString("hex"), { mode: 0o600 });
  const password = readFileSync(pw, "utf8");
  const names = Array.from({ length: 12 }, (_, i) => `k${i}`);
  for (const k of names) if (!existsSync(join(ks, k))) cast(["wallet", "new", ks, k], { CAST_PASSWORD: password });
  const file = join(home, "config.env");
  if (!existsSync(file)) {
    // Five keystores only lend their addresses to the roles that sign nothing; their keys go with the directory.
    const address = (k: string) => cast(["wallet", "address", "--keystore", join(ks, k), "--password-file", pw]);
    const lines = [
      `KEYSTORE_DIR=${ks}`, `PASSWORD_FILE=${pw}`, "DEPLOYER=k0", "GOVERNANCE=k1", "PAYLOADS_CONTROLLER=k2", "ORACLES=k3,k4,k5,k6",
      ...["TREASURY", "KEEPER", "AAVE_PROTOCOL_GUARDIAN", "EMERGENCY_GUARDIAN", "JOINT_CONFIG_SAFE"].map((r, i) => `${r}=${address(`k${7 + i}`)}`),
    ];
    writeFileSync(file, `${lines.join("\n")}\n`);
  }
  return file;
}

async function startNode(c: LocalChain, dir: string): Promise<{ url: string; proc: ChildProcess }> {
  const port = PORTS[c.network]!;
  const url = `http://127.0.0.1:${port}`;
  try {
    await rpc(url, "eth_chainId");
    throw new Error(`port ${port} is in use: set REHEARSAL_PORT_${c.envSuffix}`);
  } catch (e) {
    if ((e as Error).message.startsWith("port")) throw e;
  }
  const args = [
    "--host", "127.0.0.1", "--port", String(port), "--chain-id", String(c.chainId), "--block-time", String(c.blockTime), "--mixed-mining",
    "--gas-limit", "60000000", "--hardfork", "osaka", "--enable-tx-gas-limit", "--accounts", "0",
  ];
  const { openSync } = await import("node:fs");
  const proc = spawn("anvil", args, { stdio: ["ignore", openSync(join(dir, `anvil-${c.network}.log`), "a"), openSync(join(dir, `anvil-${c.network}.log`), "a")] });
  for (let i = 0; i < 100; i++) {
    try {
      await rpc(url, "eth_chainId");
      return { url, proc };
    } catch {
      await new Promise((r) => setTimeout(r, 300));
    }
  }
  throw new Error(`anvil for ${c.network} did not start (log ${join(dir, `anvil-${c.network}.log`)})`);
}

/** The gas and ETH each account spent on the chain: every transaction of every block. */
async function gasReport(url: string, names: Record<string, string>) {
  const head = Number(BigInt(await rpc<string>(url, "eth_blockNumber")));
  const out: Record<string, { txs: number; gas: number; wei: string }> = {};
  for (let n = 0; n <= head; n++) {
    const receipts = await rpc<{ from: string; gasUsed: string; effectiveGasPrice: string }[]>(url, "eth_getBlockReceipts", [`0x${n.toString(16)}`]);
    for (const r of receipts ?? []) {
      const who = names[r.from.toLowerCase()] ?? r.from;
      const e = (out[who] ??= { txs: 0, gas: 0, wei: "0" });
      e.txs++;
      e.gas += Number(BigInt(r.gasUsed));
      e.wei = String(BigInt(e.wei) + BigInt(r.gasUsed) * BigInt(r.effectiveGasPrice));
    }
  }
  return out;
}

async function main() {
  const release = process.env.AVANA_RELEASE;
  if (!release) throw new Error("set AVANA_RELEASE to a local tag at HEAD (not a -local, -test or -learn tag)");
  const chains = (opt("chains") ?? "sepolia,base-sepolia").split(",").map(chainOf);
  const dir = opt("dir") ?? join(tmpdir(), `avana-testnet-rehearsal-${Date.now()}`);
  const config = makeRoles(join(dir, "home"));
  say(`rehearsal in ${dir}`);
  const env = { ...process.env, AVANA_TESTNET_CONFIG: config, AVANA_REHEARSAL: "1", AVANA_RELEASE: release };
  // The role addresses, through the same code the deploy uses.
  const roles = JSON.parse(
    spawnSync(process.execPath, ["-e", 'import("./script/testnet/keys.ts").then(m=>{const r=m.testnetRoles();console.log(JSON.stringify({...r.signers,...r.addresses}))})'], { cwd: CONTRACTS, env, encoding: "utf8" }).stdout,
  ) as Record<string, string>;
  const names = Object.fromEntries(Object.entries(roles).map(([k, v]) => [v.toLowerCase(), k]));
  const nodes: ChildProcess[] = [];
  const report: Record<string, unknown> = {};
  let ok = true;
  try {
    for (const c of chains) {
      const out = outDir(c);
      if (existsSync(out) && !existsSync(join(out, ".rehearsal"))) throw new Error(`${out} exists and is not a rehearsal's: move it away first`);
      mkdirSync(out, { recursive: true });
      writeFileSync(join(out, ".rehearsal"), `${dir}\n`);
      const { url, proc } = await startNode(c, dir);
      nodes.push(proc);
      // What the real networks already have.
      await rpc(url, "anvil_setCode", [SAFE_SINGLETON_FACTORY, SAFE_SINGLETON_FACTORY_CODE]);
      await rpc(url, "anvil_setCode", [MULTICALL3, `0x${readFileSync(join(CONTRACTS, "external/multicall3/Multicall3.runtime.hex"), "utf8").trim().replace(/^0x/, "")}`]);
      // The test ETH of the signers that send transactions.
      for (const k of FUNDED_ROLES) await rpc(url, "anvil_setBalance", [roles[k], "0x3635C9ADC5DEA00000"]);
      say(`${c.network}: anvil ${c.chainId} on port ${PORTS[c.network]}, deploying`);
      const t0 = Date.now();
      const r = spawnSync(process.execPath, ["script/testnet/testnet.ts", "deploy", "--chain", c.network, "--no-verify"], {
        cwd: CONTRACTS,
        env: { ...env, [c.testnet!.rpcEnv]: url },
        stdio: "inherit",
      });
      const minutes = Math.round((Date.now() - t0) / 60_000);
      const gas = await gasReport(url, names);
      // The explorer verification has no explorer here: its dry run lists the command for every contract it found a
      // build output for, and each contract it would skip.
      const v = spawnSync(process.execPath, ["script/testnet/testnet.ts", "verify", "--chain", c.network, "--dry-run"], { cwd: CONTRACTS, env, encoding: "utf8", maxBuffer: 1 << 26 });
      writeFileSync(join(dir, `verify-dry-run-${c.network}.txt`), `${v.stdout ?? ""}${v.stderr ?? ""}`);
      const verify = { commands: (v.stdout.match(/forge verify-contract/g) ?? []).length, unmatched: (v.stdout.match(/^ {2}skip /gm) ?? []).length };
      report[c.network] = { ok: r.status === 0, minutes, gas, verify };
      say(`${c.network}: ${r.status === 0 ? "PASSED" : "FAILED"} in ${minutes} min; gas by account ${JSON.stringify(gas)}; verification dry run ${JSON.stringify(verify)}`);
      if (r.status !== 0) {
        ok = false;
        break;
      }
    }
  } finally {
    writeFileSync(join(dir, "gas-report.json"), `${JSON.stringify(report, null, 2)}\n`);
    if (!argv.includes("--keep")) for (const p of nodes) p.kill();
  }
  say(`gas report ${join(dir, "gas-report.json")}`);
  process.exitCode = ok ? 0 : 1;
}

main().catch((e: unknown) => {
  say(`FAILED ${(e as Error).stack ?? e}`);
  process.exitCode = 1;
});
