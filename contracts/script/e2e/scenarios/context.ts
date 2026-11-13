// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Shared pieces of the scenario runner (run.ts) and the market scenarios (market.ts): the deployment files of
// contracts/deployments-local/<network>, the RPC clients, the transaction and read helpers, the scripted actors and
// the Scenario and Result shapes. anvil runs with --auto-impersonate, so every actor sends unlocked.

import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  type Address,
  type PublicClient,
  type TransactionReceipt,
  type WalletClient,
  createPublicClient,
  createWalletClient,
  http,
} from "viem";

export const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
export const arg = (n: string) => {
  const i = process.argv.indexOf(`--${n}`);
  return i === -1 ? undefined : process.argv[i + 1];
};
export const network = arg("network") ?? "anvil";
export const rpc = process.env.RPC_ANVIL ?? "http://127.0.0.1:8545";
export const out = join(CONTRACTS, "deployments-local", network);
export const json = (f: string) => JSON.parse(readFileSync(join(out, f), "utf8")) as Record<string, any>;
/** A deployment file of `out`, or undefined while the step that writes it has not run. */
export const file = (f: string) => (existsSync(join(out, f)) ? json(f) : undefined);
export const manifest = json("manifest.json");
export const world = file("world.json") ?? {};
export const aave = file("aave.json") ?? {};
export const config = JSON.parse(
  readFileSync(process.env.AVANA_CONFIG ? join(CONTRACTS, process.env.AVANA_CONFIG) : join(CONTRACTS, "script/deploy/config", `${network}.json`), "utf8"),
) as Record<string, any>;

export const client = createPublicClient({ transport: http(rpc) }) as PublicClient;
export const wallet = createWalletClient({ transport: http(rpc) }) as WalletClient;

export type Outcome = "pass" | "fail" | "not-run";
export interface Result {
  readonly name: string;
  readonly outcome: Outcome;
  readonly detail: string;
  readonly numbers?: Record<string, string>;
}
export interface ScenarioRun {
  readonly ok: boolean;
  readonly detail: string;
  readonly numbers?: Record<string, string>;
}
export interface Scenario {
  readonly name: string;
  readonly needs?: "market";
  run(): Promise<ScenarioRun>;
}

export interface SendResult {
  readonly ok: boolean;
  readonly gas: bigint;
  readonly error: string;
  /** The simulated return value of the call (decoded by `abi`). */
  readonly result?: any;
  readonly receipt?: TransactionReceipt;
}

/**
 * Sends a transaction as `from` (unlocked) and waits; returns the receipt status, gas, the simulated return value and
 * the receipt, or the revert. `opts.gas` replaces the padded estimate (for a call with a gas floor at entry, such as
 * `poke()` with its `pokeMinGas`).
 */
export async function send(
  from: Address,
  to: Address,
  abi: readonly unknown[],
  fn: string,
  args: readonly unknown[],
  opts: { gas?: bigint } = {},
): Promise<SendResult> {
  try {
    const { request, result } = await client.simulateContract({ account: from, address: to, abi: abi as any, functionName: fn, args: args as any });
    // eth_estimateGas runs in the latest block's second; mined one second later, every Aave V4 Hub accrual writes its
    // index and timestamp and costs more (Lend Spoke withdraw: 31,185 vs 35,837 gas, AaveV4.LendSpokeWithdrawGas
    // integration test). The limit is padded so a call estimated in one block still fits in the next.
    let gas = opts.gas;
    if (gas === undefined) {
      const estimate = await client.estimateContractGas({ account: from, address: to, abi: abi as any, functionName: fn, args: args as any });
      gas = (estimate * 13n) / 10n + 25_000n;
    }
    const hash = await wallet.writeContract({ ...(request as any), account: from, chain: null, gas });
    const r = await client.waitForTransactionReceipt({ hash });
    if (r.status === "success") return { ok: true, gas: r.gasUsed, error: "", result, receipt: r };
    // Mined but reverted: replay the call at the block before to name the error.
    const why = await client
      .simulateContract({ account: from, address: to, abi: abi as any, functionName: fn, args: args as any, blockNumber: r.blockNumber - 1n })
      .then(() => "reverted on chain, succeeds one block earlier")
      .catch((e: Error) => e.message.split("\n").slice(0, 2).join(" "));
    return { ok: false, gas: r.gasUsed, error: `mined reverted (gas ${r.gasUsed}): ${why}`, receipt: r };
  } catch (e) {
    return { ok: false, gas: 0n, error: (e as Error).message.split("\n").slice(0, 3).join(" ") };
  }
}

export const read = (address: Address, abi: readonly unknown[], fn: string, args: readonly unknown[] = []) =>
  client.readContract({ address, abi: abi as any, functionName: fn, args: args as any }) as Promise<any>;

export const ACTORS = {
  deployer: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  governanceSafe: config.governance.governanceSafe,
  emergencyGuardian: config.governance.emergencyGuardian,
  aaveProtocolGuardian: config.governance.aaveProtocolGuardian,
  aaveExecutor: config.governance.aaveGovernanceExecutor,
  lender: "0x1000000000000000000000000000000000000a11",
  attacker: "0x1000000000000000000000000000000000000bad",
} as Record<string, Address>;

/** Everything a scenario module reads or calls; built once by run.ts. */
export interface ScenarioContext {
  readonly network: string;
  readonly out: string;
  readonly client: PublicClient;
  readonly wallet: WalletClient;
  readonly manifest: Record<string, any>;
  readonly world: Record<string, any>;
  readonly aave: Record<string, any>;
  readonly config: Record<string, any>;
  readonly actors: Record<string, Address>;
  readonly send: typeof send;
  readonly read: typeof read;
  readonly file: typeof file;
}

export const ctx: ScenarioContext = { network, out, client, wallet, manifest, world, aave, config, actors: ACTORS, send, read, file };
