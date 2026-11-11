// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Chains and contract sources built from the verified manifests. Every address and start block comes from a
// manifest; none is written in code. Contracts created after deployment (vault tokens, LPOracles, DebtOracles,
// Coverage Spokes) are followed through the event that announces them.

import { factory } from "ponder";
import { parseAbiItem } from "viem";
import { ABI_HASH } from "@avana/protocol/abis";
import {
  type ChainInfo,
  type NetworkSet,
  type ServiceManifest,
  chainsOf,
  listEnv,
  loadManifest,
  optionalEnv,
  requireEnv,
  rpcEnvName,
} from "@avana/services-common";

const NETWORK_SET = (optionalEnv(process.env, "INDEXER_NETWORK_SET") ?? "testnet") as NetworkSet;
if (NETWORK_SET !== "production" && NETWORK_SET !== "testnet") throw new Error("INDEXER_NETWORK_SET must be production or testnet");

const manifests = new Map<number, ServiceManifest>(
  listEnv(process.env, "AVANA_MANIFEST").map((path) => {
    const m = loadManifest(path, ABI_HASH);
    return [m.chainId, m] as const;
  }),
);

/** The chains of the selected set that have a manifest; a chain without one is not indexed. */
export const activeChains: ChainInfo[] = chainsOf(NETWORK_SET).filter((c) => manifests.has(c.id));
if (activeChains.length === 0) throw new Error(`no verified manifest for any ${NETWORK_SET} chain`);

/**
 * `reorgWindow` 600 s, the largest Ponder accepts: rows younger than that stay reversible at the head.
 * The export never serves above the chain's `finalized` block, so Convex sees only rows past every reorg.
 */
export function chainSources() {
  return Object.fromEntries(
    activeChains.map((c) => [
      c.key,
      {
        id: c.id,
        rpc: [requireEnv(process.env, rpcEnvName(c, "PRIMARY")), requireEnv(process.env, rpcEnvName(c, "FALLBACK"))],
        ws: optionalEnv(process.env, rpcEnvName(c, "WS")),
        reorgWindow: 600,
        ethGetLogsBlockRange: 10_000,
      },
    ]),
  );
}

/** One entry per active chain: `{ address, startBlock }`, where `address` is a list or a factory. */
export function perChain<T>(pick: (m: ServiceManifest) => T): Record<string, T> {
  return Object.fromEntries(activeChains.map((c) => [c.key, pick(manifests.get(c.id)!)]));
}

/** Start block of a chain's Avana deployment: the MarketRegistry's receipt, the first contract children announce from. */
const registryStart = (m: ServiceManifest) => m.avana.marketRegistry.startBlock;

export const vaultTokenSource = () =>
  perChain((m) => ({
    address: factory({
      address: m.avana.vaultTokenFactory.address,
      event: parseAbiItem(
        "event VaultTokenDeployed(bytes32 indexed marketKey, address indexed vaultToken, uint256 indexed marketId, uint32 integrationId, address hub, address spoke, address lpOracle, uint8 decimals)",
      ),
      parameter: "vaultToken",
    }),
    startBlock: m.avana.vaultTokenFactory.startBlock,
  }));

export const lpOracleSource = () =>
  perChain((m) => ({
    address: factory({
      address: m.avana.marketRegistry.address,
      event: parseAbiItem(
        "event MarketRegistered(uint256 indexed marketId, uint32 indexed integrationId, address pool, bytes32 poolId, address[] tokens, address vaultToken, address lpOracle, address indexed spoke)",
      ),
      parameter: "lpOracle",
    }),
    startBlock: registryStart(m),
  }));

/** For GHO the price source is the Spoke's fixed source, which emits none of these events. */
export const debtOracleSource = () =>
  perChain((m) => ({
    address: factory({
      address: m.avana.marketRegistry.address,
      event: parseAbiItem(
        "event DebtReserveApproved(address indexed spoke, uint256 indexed reserveId, address asset, address fundingHub, uint256 hubAssetId, address priceSource, address coverageSpoke)",
      ),
      parameter: "priceSource",
    }),
    startBlock: registryStart(m),
  }));

export const coverageSpokeSource = () =>
  perChain((m) => ({
    address: factory({
      address: m.avana.marketRegistry.address,
      event: parseAbiItem("event CoverageSpokeSet(address indexed hub, address indexed asset, address coverageSpoke)"),
      parameter: "coverageSpoke",
    }),
    startBlock: registryStart(m),
  }));
