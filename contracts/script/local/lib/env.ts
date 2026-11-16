// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The local stack's layout: its two anvil chains, their ports, and where every file of the stack lives. Nothing here
// holds a key: signers are encrypted Foundry keystores (keys.ts), and the governance roles are anvil's unlocked
// senders (anvil --auto-impersonate).

import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
export const REPO = resolve(CONTRACTS, "..");
/** Everything the stack writes that belongs to no single chain: keystores, process records, service state, logs. */
export const STACK = join(CONTRACTS, "deployments-local", "stack");
export const LOGS = join(STACK, "logs");
export const PIDS = join(STACK, "pids");

export interface LocalChain {
  /** The deploy scripts' network name (AVANA_NETWORK), as on the real network: its outputs go to
   * deployments-local/<network>. The chain ID makes the run local (31337, 31338), not the name. */
  readonly network: string;
  /** The services' chain key for this chain ID (services/common/src/chains.ts, network set `local`). */
  readonly key: string;
  readonly chainId: number;
  readonly label: string;
  /** RPC_<envSuffix>, the name every service reads. */
  readonly envSuffix: string;
  readonly port: number;
  /** The rpc-recorder in front of the node for the indexer (contracts/script/e2e/rpc-recorder.ts). */
  readonly recorderPort: number;
  readonly blockTime: number;
  readonly forkUrl: string | undefined;
}

const int = (name: string, d: number) => (process.env[name] ? Number(process.env[name]) : d);

export const CHAINS: readonly LocalChain[] = [
  {
    network: "ethereum",
    key: "anvil",
    chainId: 31337,
    label: "Ethereum",
    envSuffix: "ANVIL",
    port: int("STACK_PORT_ETHEREUM", 8545),
    recorderPort: int("STACK_RECORDER_PORT_ETHEREUM", 8549),
    blockTime: 12,
    forkUrl: process.env.STACK_FORK_ETHEREUM || undefined,
  },
  {
    network: "base",
    key: "anvilBase",
    chainId: 31338,
    label: "Base",
    envSuffix: "ANVIL_BASE",
    port: int("STACK_PORT_BASE", 8546),
    recorderPort: int("STACK_RECORDER_PORT_BASE", 8550),
    blockTime: 2,
    forkUrl: process.env.STACK_FORK_BASE || undefined,
  },
];

export const chainOf = (network: string): LocalChain => {
  const c = CHAINS.find((x) => x.network === network || x.key === network || String(x.chainId) === network);
  if (!c) throw new Error(`no local chain ${network}: ${CHAINS.map((x) => x.network).join(", ")}`);
  return c;
};

export const rpcUrl = (c: LocalChain) => `http://127.0.0.1:${c.port}`;
/** A second spelling of the same node: the monitor and the keeper refuse a fallback equal to the primary. */
export const fallbackUrl = (c: LocalChain) => `http://localhost:${c.port}`;
export const recorderUrl = (c: LocalChain) => `http://127.0.0.1:${c.recorderPort}`;
export const outDir = (c: LocalChain) => join(CONTRACTS, "deployments-local", c.network);
export const manifestPath = (c: LocalChain) => join(outDir(c), "manifest.json");

export const PORTS = {
  indexer: int("STACK_INDEXER_PORT", 42070),
  content: int("STACK_CONTENT_PORT", 8788),
  keeperMetrics: int("STACK_KEEPER_METRICS_PORT", 9464),
  keeperKill: int("STACK_KEEPER_KILL_PORT", 9465),
  monitor: int("STACK_MONITOR_PORT", 9470),
  webapp: int("STACK_WEBAPP_PORT", 3000),
};

/** The indexer export's key ID; its HMAC secret is a random file in STACK (not a signing key). */
export const EXPORT_KEY_ID = "stack";

/**
 * Chain time at genesis: the deploy moves the clock past three 5-day timelock delays, so the chain starts this many days
 * before now and lands near the present when the first release is live (STACK_GENESIS_DAYS_AGO, default 35, leaves room
 * for the sandbox markets' release).
 */
export const genesisTimestamp = () => Math.floor(Date.now() / 1000) - int("STACK_GENESIS_DAYS_AGO", 35) * 86_400;
