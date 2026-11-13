// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Chains and contract sources built from the verified manifests. Every address and start block comes from a
// manifest; none is written in code. Contracts created after deployment (vault tokens, LPOracles, DebtOracles,
// Coverage Spokes, recorded Hubs, approved CDP Spokes, Spokes a Hub adds) are followed through the event that
// announces them.

import { factory } from "ponder";
import { ABI_HASH } from "@avana/protocol/abis";
import { factoryEvents } from "./abis.ts";
import {
  type ChainInfo,
  type NetworkSet,
  type ServiceManifest,
  aaveTopology,
  chainsOf,
  listEnv,
  loadManifest,
  optionalEnv,
  requireEnv,
  rpcEnvName,
} from "@avana/services-common";
import type { ChainDeployment } from "@avana/services-common/views";

const NETWORK_SET = (optionalEnv(process.env, "INDEXER_NETWORK_SET") ?? "testnet") as NetworkSet;
if (NETWORK_SET !== "production" && NETWORK_SET !== "testnet" && NETWORK_SET !== "local") {
  throw new Error("INDEXER_NETWORK_SET must be production, testnet or local");
}

const manifests = new Map<number, ServiceManifest>(
  listEnv(process.env, "AVANA_MANIFEST").map((path) => {
    const m = loadManifest(path, ABI_HASH);
    aaveTopology(m); // refuses a manifest without a Hub or a Lend Spoke at start-up
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
      event: factoryEvents.vaultTokenDeployed,
      parameter: "vaultToken",
    }),
    startBlock: m.avana.vaultTokenFactory.startBlock,
  }));

export const lpOracleSource = () =>
  perChain((m) => ({
    address: factory({
      address: m.avana.marketRegistry.address,
      event: factoryEvents.marketRegistered,
      parameter: "lpOracle",
    }),
    startBlock: registryStart(m),
  }));

/** For GHO the price source is the Spoke's fixed source, which emits none of these events. */
export const debtOracleSource = () =>
  perChain((m) => ({
    address: factory({
      address: m.avana.marketRegistry.address,
      event: factoryEvents.debtReserveApproved,
      parameter: "priceSource",
    }),
    startBlock: registryStart(m),
  }));

export const coverageSpokeSource = () =>
  perChain((m) => ({
    address: factory({
      address: m.avana.marketRegistry.address,
      event: factoryEvents.coverageSpokeSet,
      parameter: "coverageSpoke",
    }),
    startBlock: registryStart(m),
  }));

/** The addresses the series sampler starts from on a chain (`@avana/services-common/views`), from its manifest. */
export function deploymentOf(chainId: number): ChainDeployment {
  const m = manifests.get(chainId);
  if (!m) throw new Error(`no verified manifest for chain ${chainId}`);
  const t = aaveTopology(m);
  return {
    chainId,
    lens: m.avana.lens.address,
    marketRegistry: m.avana.marketRegistry.address,
    hubs: t.hubs.map((h) => ({ address: h.address, label: h.label })),
    lendSpokes: t.lendSpokes.map((s) => s.address),
    cdpSpokes: t.borrowSpokes.map((s) => s.address),
    coverageSpokes: m.avana.coverageSpokes.map((c) => ({ address: c.address, asset: c.asset, hub: c.hub })),
  };
}

const earliest = (xs: readonly { address: `0x${string}`; startBlock: number }[]) => ({ address: xs.map((x) => x.address), startBlock: Math.min(...xs.map((x) => x.startBlock)) });

/** The manifest's Hubs. */
export const hubSource = () => perChain((m) => earliest(aaveTopology(m).hubs));

/** The manifest's Lend and CDP Spokes. */
export const spokeSource = () =>
  perChain((m) => {
    const t = aaveTopology(m);
    return earliest([...t.borrowSpokes, ...t.lendSpokes]);
  });

/** Hubs the MarketRegistry records, a Hub recorded after the manifest included. */
export const hubRecordedSource = () =>
  perChain((m) => ({ address: factory({ address: m.avana.marketRegistry.address, event: factoryEvents.hubRecorded, parameter: "hub" }), startBlock: registryStart(m) }));

/** CDP Spokes the MarketRegistry approves, on any Hub. */
export const spokeApprovedSource = () =>
  perChain((m) => ({ address: factory({ address: m.avana.marketRegistry.address, event: factoryEvents.spokeApproved, parameter: "spoke" }), startBlock: registryStart(m) }));

/** Every Spoke a manifest Hub adds to one of its assets, a Lend Spoke added after the manifest included. */
export const spokeAddedSource = () =>
  perChain((m) => {
    const hubs = earliest(aaveTopology(m).hubs);
    return { address: factory({ address: hubs.address, event: factoryEvents.addSpoke, parameter: "spoke" }), startBlock: hubs.startBlock };
  });

/**
 * Pools of listed markets, followed from `MarketRegistered`. Ponder matches a pool's logs only from the block that
 * announced it; the history before listing is served by the export's pool-history endpoint (EXPORT.md).
 */
export const ammPoolSource = () =>
  perChain((m) => ({
    address: factory({
      address: m.avana.marketRegistry.address,
      event: factoryEvents.marketRegistered,
      parameter: "pool",
    }),
    startBlock: registryStart(m),
  }));

/** One sample an hour of block time, from the later of the Lens and the first Lend Spoke deployments. */
export function samplerSource() {
  return Object.fromEntries(
    activeChains.map((c) => {
      const m = manifests.get(c.id)!;
      const firstLend = Math.min(...aaveTopology(m).lendSpokes.map((s) => s.startBlock));
      return [c.key, { startBlock: Math.max(m.avana.lens.startBlock, firstLend), interval: Math.round(3_600 / c.blockTimeSeconds) }];
    }),
  );
}
