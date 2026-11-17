// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The local stack's layout: its two anvil chains, their ports, and where every file of the stack lives. Nothing here
// holds a key: signers are encrypted Foundry keystores (keys.ts), and the governance roles are anvil's unlocked
// senders (anvil --auto-impersonate).

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
export const REPO = resolve(CONTRACTS, "..");
/** Everything the stack writes that belongs to no single chain: keystores, process records, service state, logs. */
export const STACK = join(CONTRACTS, "deployments-local", "stack");
/** Process logs and records (procs.ts): the stack's, or another run's directory (STACK_RUN_DIR, the test-network app's
 * script/testnet/app.ts), so two runs on one checkout never share a process name. */
const RUN = process.env.STACK_RUN_DIR ?? STACK;
export const LOGS = join(RUN, "logs");
export const PIDS = join(RUN, "pids");

export interface LocalChain {
  /** The deploy scripts' network name (AVANA_NETWORK), as on the real network: its outputs go to
   * deployments-local/<network>. The chain ID makes the run local (31337, 31338), not the name. */
  readonly network: string;
  /** The chain's Hub: its label in the config, its page ("Avana <label> Hub") and its Hub files'
   * folder, script/deploy/hubs/<hubs>/ (`ethereum` on Ethereum and Sepolia, `base` on Base and Base Sepolia). */
  readonly hubs: string;
  /** A public test network (Sepolia, Base Sepolia) deployed from keystores (script/testnet/): no anvil method is
   * called, its RPC URL comes from `rpcEnv`, and each signer from the testnet keystores. */
  readonly testnet?: { readonly rpcEnv: string };
  /** The services' chain key (services/common/src/chains.ts, network set `production`): the services read this node as
   * that chain through RPC_<envSuffix> and CHAIN_ID_<envSuffix>. */
  readonly key: string;
  readonly chainId: number;
  readonly label: string;
  /** RPC_<envSuffix>, the name every service reads. */
  readonly envSuffix: string;
  readonly port: number;
  /** The rpc-recorder in front of the node for the indexer (contracts/script/e2e/rpc-recorder.ts). */
  readonly recorderPort: number;
  readonly blockTime: number;
  /** Fork mode (STACK_FORK=1): the real network at the block pinned in fork.json, read through the fork proxy. */
  readonly fork: { readonly block: number; readonly proxyPort: number } | undefined;
}

/**
 * Fork mode: every chain forks its real network at the block pinned in fork.json, so runs are repeatable and anvil
 * caches what it read; STACK_FORK_BLOCK_<CHAIN> pins another. The network's RPC endpoints are never in the repository:
 * <CHAIN>_FORK_RPC_URL comes from the environment or the encrypted secrets file (secrets.ts), and anvil reaches them
 * through the local fork proxy (fork-proxy.ts), so they appear on no command line either.
 */
function forkOf(network: string, proxyPort: number): LocalChain["fork"] {
  if (process.env.STACK_FORK !== "1") return undefined;
  const pinned = (JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "fork.json"), "utf8")) as Record<string, { block: number }>)[network];
  if (!pinned) throw new Error(`fork.json has no ${network}`);
  return { block: Number(process.env[`STACK_FORK_BLOCK_${network.toUpperCase()}`] ?? pinned.block), proxyPort };
}

const int = (name: string, d: number) => (process.env[name] ? Number(process.env[name]) : d);

export const CHAINS: readonly LocalChain[] = [
  {
    network: "ethereum",
    hubs: "ethereum",
    key: "mainnet",
    chainId: 31337,
    label: "Ethereum",
    envSuffix: "MAINNET",
    port: int("STACK_PORT_ETHEREUM", 8545),
    recorderPort: int("STACK_RECORDER_PORT_ETHEREUM", 8549),
    blockTime: 12,
    fork: forkOf("ethereum", int("STACK_FORK_PROXY_PORT_ETHEREUM", 8559)),
  },
  {
    network: "base",
    hubs: "base",
    key: "base",
    chainId: 31338,
    label: "Base",
    envSuffix: "BASE",
    port: int("STACK_PORT_BASE", 8546),
    recorderPort: int("STACK_RECORDER_PORT_BASE", 8550),
    blockTime: 2,
    fork: forkOf("base", int("STACK_FORK_PROXY_PORT_BASE", 8560)),
  },
];

/**
 * The public test networks, deployed as the local stack is (the same base config, Hub files, world and test values)
 * by script/testnet/testnet.ts. Their RPC URLs are secrets: `rpcEnv` names the variable (environment, or the encrypted
 * secrets file of secrets.ts); they never reach a command line or a log.
 */
export const TESTNETS: readonly LocalChain[] = [
  {
    network: "sepolia",
    hubs: "ethereum",
    key: "sepolia",
    chainId: 11_155_111,
    label: "Ethereum",
    envSuffix: "SEPOLIA",
    port: 0,
    recorderPort: 0,
    blockTime: 12,
    fork: undefined,
    testnet: { rpcEnv: "SEPOLIA_RPC_URL" },
  },
  {
    network: "base-sepolia",
    hubs: "base",
    key: "base-sepolia",
    chainId: 84_532,
    label: "Base",
    envSuffix: "BASE_SEPOLIA",
    port: 0,
    recorderPort: 0,
    blockTime: 2,
    fork: undefined,
    testnet: { rpcEnv: "BASE_SEPOLIA_RPC_URL" },
  },
];

export const chainOf = (network: string): LocalChain => {
  const all = [...CHAINS, ...TESTNETS];
  const c = all.find((x) => x.network === network || x.key === network || String(x.chainId) === network);
  if (!c) throw new Error(`no chain ${network}: ${all.map((x) => x.network).join(", ")}`);
  return c;
};

/** The chain's RPC: the local node's port, or a test network's URL from its secret variable. */
export const rpcUrl = (c: LocalChain) => {
  if (!c.testnet) return `http://127.0.0.1:${c.port}`;
  const url = process.env[c.testnet.rpcEnv]?.trim();
  if (!url) throw new Error(`${c.testnet.rpcEnv} is not set: store it with \`node script/local/stack.ts secrets\` or set it in the environment`);
  return url;
};
/** What every service reads to know which node stands in for which chain. */
export const chainIdEnv = (): Record<string, string> => Object.fromEntries(CHAINS.map((c) => [`CHAIN_ID_${c.envSuffix}`, String(c.chainId)]));
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
  faucet: int("STACK_FAUCET_PORT", 42080),
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
