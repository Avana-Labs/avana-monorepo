// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The chains the services run on, with the names that pick their environment variables: Ethereum and Base in
// production, Sepolia and Base Sepolia for the public test deployment, and the local anvil network of the
// deployment rehearsals (deployments/README.md), which are never published.

export type ChainKey = "mainnet" | "base" | "sepolia" | "baseSepolia" | "anvil";

/** Ethereum and Base in production; Sepolia and Base Sepolia for the public test deployment; anvil for
 * rehearsals. */
export type NetworkSet = "production" | "testnet" | "local";

export interface ChainInfo {
  readonly key: ChainKey;
  readonly id: number;
  /** Suffix of every `RPC_<SUFFIX>` and `KEEPER_KMS_KEY_ID_<SUFFIX>` name, the same names as `contracts/.env.example`. */
  readonly envSuffix: "MAINNET" | "BASE" | "SEPOLIA" | "BASE_SEPOLIA" | "ANVIL";
  readonly networkSet: NetworkSet;
  /** Block time in seconds; sets the 3-block liquidation deadline (REQ-SWAP-074) and the M-09 block counts. */
  readonly blockTimeSeconds: number;
  /** True on an L2 whose sequencer-uptime feed gates borrowing and liquidation (EMG-093, EMG-094). */
  readonly hasSequencer: boolean;
  /** Ethereum sends to builder endpoints; Base sends to the sequencer endpoint (no public mempool). */
  readonly privateFlow: "builders" | "sequencer";
}

/**
 * Multicall3, at the same address on every chain the services read (deployed by its keyless transaction; placed at the
 * same address on a local anvil node). Passed explicitly to every `multicall`, because viem's chain definition for
 * anvil names none.
 */
export const MULTICALL3_ADDRESS = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;

export const CHAINS: Readonly<Record<ChainKey, ChainInfo>> = {
  mainnet: { key: "mainnet", id: 1, envSuffix: "MAINNET", networkSet: "production", blockTimeSeconds: 12, hasSequencer: false, privateFlow: "builders" },
  base: { key: "base", id: 8453, envSuffix: "BASE", networkSet: "production", blockTimeSeconds: 2, hasSequencer: true, privateFlow: "sequencer" },
  sepolia: { key: "sepolia", id: 11155111, envSuffix: "SEPOLIA", networkSet: "testnet", blockTimeSeconds: 12, hasSequencer: false, privateFlow: "builders" },
  baseSepolia: { key: "baseSepolia", id: 84532, envSuffix: "BASE_SEPOLIA", networkSet: "testnet", blockTimeSeconds: 2, hasSequencer: true, privateFlow: "sequencer" },
  anvil: { key: "anvil", id: 31337, envSuffix: "ANVIL", networkSet: "local", blockTimeSeconds: 12, hasSequencer: false, privateFlow: "builders" },
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
