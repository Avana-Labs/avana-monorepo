// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The chains the services run on, with the names that pick their environment variables: Ethereum and Base in
// production, Sepolia and Base Sepolia for the public test deployment. The environment chooses the node: each chain's
// RPC (RPC_<SUFFIX>) and, for a development node, its chain ID (CHAIN_ID_<SUFFIX>, for example CHAIN_ID_MAINNET=31337
// for a local anvil node standing in for Ethereum). Names never change between a local run, Sepolia and production.

export type ChainKey = "mainnet" | "base" | "sepolia" | "baseSepolia";

/** Ethereum and Base in production; Sepolia and Base Sepolia for the public test deployment. */
export type NetworkSet = "production" | "testnet";

export interface ChainInfo {
  readonly key: ChainKey;
  readonly id: number;
  /** Suffix of every `RPC_<SUFFIX>`, `CHAIN_ID_<SUFFIX>` and `KEEPER_KMS_KEY_ID_<SUFFIX>` name, the same names as
   * `contracts/.env.example`. */
  readonly envSuffix: "MAINNET" | "BASE" | "SEPOLIA" | "BASE_SEPOLIA";
  readonly networkSet: NetworkSet;
  /** Block time in seconds; sets the 3-block liquidation deadline (REQ-SWAP-074) and the M-09 block counts. */
  readonly blockTimeSeconds: number;
  /** True on an L2 run by a sequencer, with a sequencer-uptime feed (recorded in the ParameterStore). */
  readonly hasSequencer: boolean;
  /** Ethereum sends to builder endpoints; Base sends to the sequencer endpoint (no public mempool). */
  readonly privateFlow: "builders" | "sequencer";
}

/**
 * Chain IDs of development nodes (anvil). Only there does the keeper sign from a local keystore and the indexer follow
 * every Hub's `AddSpoke`; a published deployment never runs on one.
 */
export const DEV_CHAIN_IDS: ReadonlySet<number> = new Set([31337, 31338]);
export const isDevChain = (c: Pick<ChainInfo, "id">) => DEV_CHAIN_IDS.has(c.id);

/**
 * Multicall3, at the same address on every chain the services read (deployed by its keyless transaction; placed at the
 * same address on a local anvil node). Passed explicitly to every `multicall`, because viem's chain definition for
 * anvil names none.
 */
export const MULTICALL3_ADDRESS = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;

/** CHAIN_ID_<SUFFIX> when set (a development node), else the network's own chain ID. */
function chainId(suffix: ChainInfo["envSuffix"], id: number): number {
  const v = typeof process === "undefined" ? undefined : process.env?.[`CHAIN_ID_${suffix}`];
  if (v === undefined || v.trim() === "") return id;
  const n = Number(v);
  if (!Number.isSafeInteger(n) || n <= 0) throw new Error(`CHAIN_ID_${suffix} must be a positive integer`);
  if (n !== id && !DEV_CHAIN_IDS.has(n)) throw new Error(`CHAIN_ID_${suffix} ${n} is neither the network's ${id} nor a development node's (${[...DEV_CHAIN_IDS].join(", ")})`);
  return n;
}

export const CHAINS: Readonly<Record<ChainKey, ChainInfo>> = {
  mainnet: { key: "mainnet", id: chainId("MAINNET", 1), envSuffix: "MAINNET", networkSet: "production", blockTimeSeconds: 12, hasSequencer: false, privateFlow: "builders" },
  base: { key: "base", id: chainId("BASE", 8453), envSuffix: "BASE", networkSet: "production", blockTimeSeconds: 2, hasSequencer: true, privateFlow: "sequencer" },
  sepolia: { key: "sepolia", id: chainId("SEPOLIA", 11155111), envSuffix: "SEPOLIA", networkSet: "testnet", blockTimeSeconds: 12, hasSequencer: false, privateFlow: "builders" },
  baseSepolia: { key: "baseSepolia", id: chainId("BASE_SEPOLIA", 84532), envSuffix: "BASE_SEPOLIA", networkSet: "testnet", blockTimeSeconds: 2, hasSequencer: true, privateFlow: "sequencer" },
};

export function chainsOf(set: NetworkSet): ChainInfo[] {
  return Object.values(CHAINS).filter((c) => c.networkSet === set);
}

export function chainById(id: number): ChainInfo {
  const found = Object.values(CHAINS).find((c) => c.id === id);
  if (!found) throw new Error(`unsupported chain ${id}`);
  return found;
}

/** Number of blocks covering `seconds` on a chain, rounded up. */
export function blocksFor(chain: ChainInfo, seconds: number): number {
  return Math.ceil(seconds / chain.blockTimeSeconds);
}
