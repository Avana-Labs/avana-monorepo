// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Chains and contract sources built from the verified manifests. Every address and start block comes from a
// manifest; none is written in code. Each integration's core stack (AaveAdapter, RiskModule, LiquidationModule,
// FlashloanRepay, LPVault) is one source per contract kind over every integration. Contracts created after deployment
// (vault tokens of markets activated later, First-Loss Reserves set later, Spokes a Hub adds) are followed through the
// event that announces them. The LPOracles and the Chainlink feeds emit no events and are not indexed. The AMM pools
// are the manifest's markets' pools: a pool listed after the manifest is followed from the next release manifest.

import { factory } from "ponder";
import {
  type ChainInfo,
  DEV_CHAIN_IDS,
  type NetworkSet,
  type ServiceManifest,
  aaveTopology,
  chainsOf,
  optionalEnv,
  requireEnv,
  rpcEnvName,
  uniswapV4PoolManager,
} from "@avana/services-common";
import { type ChainDeployment, chainDeploymentOf } from "@avana/services-common/views";
import { factoryEvents } from "./abis.ts";
import { manifests as loadedManifests, poolAddressOf } from "./integrations.ts";

export { integrationOfRiskModule, lpVaultOfAdapter, poolAddressOf } from "./integrations.ts";

const NETWORK_SET = (optionalEnv(process.env, "INDEXER_NETWORK_SET") ?? "testnet") as NetworkSet;
if (NETWORK_SET !== "production" && NETWORK_SET !== "testnet") {
  throw new Error("INDEXER_NETWORK_SET must be production or testnet");
}

const manifests = loadedManifests();

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

/** Start block of a chain's Avana deployment: its AccessManager's receipt, before every core contract. */
const avanaStart = (m: ServiceManifest) => m.avana.accessManager.startBlock;

/** One core contract kind over every integration of each chain. */
export const coreSource = (kind: "aaveAdapter" | "riskModule" | "liquidationModule" | "flashloanRepay" | "lpVault") =>
  perChain((m) => earliest(m.avana.integrations.map((x) => x[kind])));

/** Entries only for the chains where `pick` lists something (Ponder refuses an empty address list). */
function whereListed(pick: (m: ServiceManifest) => readonly { address: `0x${string}`; startBlock: number }[]) {
  return Object.fromEntries(
    activeChains.flatMap((c) => {
      const xs = pick(manifests.get(c.id)!);
      return xs.length ? [[c.key, earliest(xs)] as const] : [];
    }),
  );
}

/** The operator flash liquidators, on chains that have one. */
export const flashLiquidatorSource = () => whereListed((m) => m.avana.flashLiquidators);

/** The manifest's vault tokens, from their deployment blocks (a market's tokens are minted only after activation). */
export const vaultTokenListedSource = () => whereListed((m) => m.markets.map((mk) => mk.vaultToken));

/** Vault tokens of markets any RiskModule activates, a market activated after the manifest included. */
export const vaultTokenSource = () =>
  perChain((m) => ({
    address: factory({ address: m.avana.integrations.map((x) => x.riskModule.address), event: factoryEvents.marketActivated, parameter: "vaultToken" }),
    startBlock: avanaStart(m),
  }));

/** The First-Loss Reserves and DAO deficit offsets each manifest lists, from their deployment blocks. */
export const firstLossReserveListedSource = () => whereListed((m) => [...m.coverage.firstLossReserves, ...m.coverage.daoDeficitOffsets]);

/** First-Loss Reserves a RiskModule registers for a debt reserve (`DebtReserveSet`), one set after the manifest included. */
export const firstLossReserveSource = () =>
  perChain((m) => ({
    address: factory({ address: m.avana.integrations.map((x) => x.riskModule.address), event: factoryEvents.debtReserveSet, parameter: "firstLossReserve" }),
    startBlock: avanaStart(m),
  }));

/** The addresses the series sampler reads on a chain (`@avana/services-common/views`), from its manifest. */
export function deploymentOf(chainId: number): ChainDeployment {
  const m = manifests.get(chainId);
  if (!m) throw new Error(`no verified manifest for chain ${chainId}`);
  return chainDeploymentOf(m);
}



/** The manifest's Hubs. */
export const hubSource = () => perChain((m) => earliest(aaveTopology(m).hubs));

/** The manifest's Lend and CDP Spokes. */
export const spokeSource = () =>
  perChain((m) => {
    const t = aaveTopology(m);
    return earliest([...t.borrowSpokes, ...t.lendSpokes]);
  });

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
 * The pools of the manifest's markets on concentrated-liquidity integrations (Uniswap v3, Slipstream), from the AccessManager's
 * deployment on: the handlers keep a pool's logs from its `PoolListed` on, and earlier history is served by the
 * pool-history endpoint (EXPORT.md). Only chains with one.
 */
export const ammPoolSource = () =>
  whereListed((m) => {
    const cl = new Set(m.avana.integrations.filter((x) => x.kind !== "uniswap-v4").map((x) => x.integrationId));
    const pools = [...new Set(m.markets.filter((mk) => cl.has(mk.integrationId)).map((mk) => poolAddressOf(mk.pool)))];
    return pools.map((address) => ({ address, startBlock: avanaStart(m) }));
  });

/**
 * A manifest's Uniswap v4 PoolManager, from the later of its deployment and Avana's: the handlers keep only pools a
 * market lists, and a pool's history before listing is not part of the live series. Null without one.
 */
export function poolManagerOf(m: Pick<ServiceManifest, "uniswapV4" | "avana">): { address: `0x${string}`; startBlock: number } | null {
  const pm = uniswapV4PoolManager(m);
  return pm ? { address: pm.address, startBlock: Math.max(pm.startBlock, m.avana.accessManager.startBlock) } : null;
}

/** The PoolManager of every active chain whose manifest names one; empty, and so inert, when none does. */
export const poolManagerSource = () =>
  Object.fromEntries(
    activeChains.flatMap((c) => {
      const pm = poolManagerOf(manifests.get(c.id)!);
      return pm ? [[c.key, pm] as const] : [];
    }),
  );

/** One sample an hour of block time, from the later of Avana's and the first Lend Spoke's deployment. */
export function samplerSource() {
  return Object.fromEntries(
    activeChains.map((c) => {
      const m = manifests.get(c.id)!;
      const firstLend = Math.min(...aaveTopology(m).lendSpokes.map((s) => s.startBlock));
      return [c.key, { startBlock: Math.max(avanaStart(m), firstLend), interval: Math.round(3_600 / c.blockTimeSeconds) }];
    }),
  );
}
