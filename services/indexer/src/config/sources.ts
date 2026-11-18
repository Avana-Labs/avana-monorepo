// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Chains and contract sources built from the verified manifests. Every address and start block comes from a
// manifest; none is written in code. Contracts created after deployment (vault tokens, First-Loss Reserves, recorded
// Hubs, approved CDP Spokes, Spokes a Hub adds, market pools) are followed through the event that announces them. The
// stateless LPOracles and the debt assets' Chainlink feeds emit no events and are not indexed.

import { factory } from "ponder";
import { ABI_HASH } from "@avana/protocol/abis";
import { factoryEvents } from "./abis.ts";
import {
  type ChainInfo,
  DEV_CHAIN_IDS,
  type NetworkSet,
  type ServiceManifest,
  aaveTopology,
  chainsOf,
  listEnv,
  loadManifest,
  optionalEnv,
  requireEnv,
  rpcEnvName,
  uniswapV4PoolManager,
} from "@avana/services-common";
import type { ChainDeployment } from "@avana/services-common/views";

const NETWORK_SET = (optionalEnv(process.env, "INDEXER_NETWORK_SET") ?? "testnet") as NetworkSet;
if (NETWORK_SET !== "production" && NETWORK_SET !== "testnet") {
  throw new Error("INDEXER_NETWORK_SET must be production or testnet");
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

const earliest = (xs: readonly { address: `0x${string}`; startBlock: number }[]) => ({ address: xs.map((x) => x.address), startBlock: Math.min(...xs.map((x) => x.startBlock)) });

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

export const firstLossReserveSource = () =>
  perChain((m) => ({
    address: factory({
      address: m.avana.marketRegistry.address,
      event: factoryEvents.firstLossReserveSet,
      parameter: "firstLossReserve",
    }),
    startBlock: registryStart(m),
  }));

/**
 * The First-Loss Reserves each manifest lists, from their deployment blocks: the release funds a reserve before the
 * MarketRegistry sets it, and `firstLossReserveSource` follows a reserve only from that event. Only chains whose
 * manifest lists one (Ponder refuses an empty address list).
 */
export const firstLossReserveListedSource = () =>
  Object.fromEntries(
    activeChains.flatMap((c) => {
      const reserves = manifests.get(c.id)!.avana.firstLossReserves;
      return reserves.length ? [[c.key, earliest(reserves)] as const] : [];
    }),
  );

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
    firstLossReserves: m.avana.firstLossReserves.map((c) => ({ address: c.address, asset: c.asset, hub: c.hub })),
  };
}

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

/**
 * Every Spoke a manifest Hub adds to one of its assets, a Lend Spoke added after the manifest included. On a development
 * node (CHAIN_ID_<SUFFIX> 31337 or 31338), every Spoke any Hub adds: it holds only Avana's Hubs, and a Hub the operator
 * adds to a running local stack (contracts/script/local) is not in the manifest the indexer started on, so its Lend
 * Spoke is followed from its `AddSpoke` too. Elsewhere a new Hub comes with a new release manifest.
 */
export const spokeAddedSource = () =>
  perChain((m) => {
    const hubs = earliest(aaveTopology(m).hubs);
    const from = DEV_CHAIN_IDS.has(m.chainId) ? {} : { address: hubs.address };
    return { address: factory({ ...from, event: factoryEvents.addSpoke, parameter: "spoke" }), startBlock: hubs.startBlock };
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

/**
 * A manifest's Uniswap v4 PoolManager, from the later of its deployment and the registry's: the handlers keep only
 * pools a market lists, and a pool's history before listing is not part of the live series. Null without one.
 */
export function poolManagerOf(m: Pick<ServiceManifest, "uniswapV4" | "avana">): { address: `0x${string}`; startBlock: number } | null {
  const pm = uniswapV4PoolManager(m);
  return pm ? { address: pm.address, startBlock: Math.max(pm.startBlock, m.avana.marketRegistry.startBlock) } : null;
}

/** The PoolManager of every active chain whose manifest names one; empty, and so inert, when none does. */
export const poolManagerSource = () =>
  Object.fromEntries(
    activeChains.flatMap((c) => {
      const pm = poolManagerOf(manifests.get(c.id)!);
      return pm ? [[c.key, pm] as const] : [];
    }),
  );

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
