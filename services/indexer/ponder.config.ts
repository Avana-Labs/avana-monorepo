// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Ponder configuration: Ethereum and Base, or Sepolia and Base Sepolia (INDEXER_NETWORK_SET), from the verified
// manifests named in AVANA_MANIFEST. EVENTS.md lists every event each source is indexed for.

import { createConfig } from "ponder";
import { abis } from "./src/config/abis.ts";
import { clPoolAbi, uniswapV4PoolManagerAbi } from "@avana/services-common/views";
import {
  activeChains,
  ammPoolSource,
  chainSources,
  coreSource,
  firstLossReserveListedSource,
  firstLossReserveSource,
  flashLiquidatorSource,
  hubSource,
  perChain,
  poolManagerSource,
  samplerSource,
  spokeAddedSource,
  spokeSource,
  vaultTokenListedSource,
  vaultTokenSource,
} from "./src/config/sources.ts";

const a = (x: { address: `0x${string}`; startBlock: number }) => ({ address: x.address, startBlock: x.startBlock });

export default createConfig({
  ordering: "multichain",
  // PostgreSQL in production and on the test networks; the embedded PGlite store (INDEXER_DATABASE=pglite) only for a
  // local run on development nodes, so the rehearsal and the local stack need no database server.
  database: process.env.INDEXER_DATABASE === "pglite" ? { kind: "pglite", directory: ".ponder/pglite" } : { kind: "postgres" },
  chains: chainSources(),
  contracts: {
    // One core stack per AMM integration; each source covers that contract of every integration.
    AaveAdapter: { abi: abis.AaveAdapter, chain: coreSource("aaveAdapter") },
    RiskModule: { abi: abis.RiskModule, chain: coreSource("riskModule") },
    LiquidationModule: { abi: abis.LiquidationModule, chain: coreSource("liquidationModule") },
    FlashloanRepay: { abi: abis.FlashloanRepay, chain: coreSource("flashloanRepay") },
    LPVault: { abi: abis.LPVault, chain: coreSource("lpVault") },
    AccessManager: { abi: abis.AccessManager, chain: perChain((m) => a(m.avana.accessManager)) },
    FlashLiquidator: { abi: abis.FlashLiquidator, chain: flashLiquidatorSource() },
    // Vault tokens: the manifest's from their deployment, and every one a RiskModule activates, from that event.
    VaultTokenListed: { abi: abis.VaultToken, chain: vaultTokenListedSource() },
    VaultToken: { abi: abis.VaultToken, chain: vaultTokenSource() },
    // Loss layers: the manifest's First-Loss Reserves and DAO deficit offsets, every First-Loss Reserve a RiskModule
    // registers, and every Spoke a manifest Hub adds (a deficit offset the DAO registers later), decoded with the
    // First-Loss Reserve ABI (src/config/aaveSources.ts, FIRST_LOSS_SOURCES).
    FirstLossReserveListed: { abi: abis.FirstLossReserve, chain: firstLossReserveListedSource() },
    FirstLossReserve: { abi: abis.FirstLossReserve, chain: firstLossReserveSource() },
    DaoDeficitOffset: { abi: abis.FirstLossReserve, chain: spokeAddedSource() },
    // Aave V4: every Hub and every Lend and CDP Spoke, the manifest's and those a Hub adds later (src/config/aaveSources.ts).
    // Spoke events are attributed only to accounts the AaveAdapter announced.
    AaveSpoke: { abi: abis.AaveSpoke, chain: spokeSource() },
    AaveSpokeAdded: { abi: abis.AaveSpoke, chain: spokeAddedSource() },
    AaveHub: { abi: abis.AaveHub, chain: hubSource() },
    // The AMM pool of every listed market, for its volume, fee and price series.
    AmmPool: { abi: clPoolAbi, chain: ammPoolSource() },
    // The Uniswap v4 PoolManager of a chain whose manifest names one; only pools a market lists by PoolId are kept.
    UniswapV4PoolManager: { abi: uniswapV4PoolManagerAbi, chain: poolManagerSource() },
  },
  // One row per chain records the last block handled at the realtime head; the export never serves past it.
  blocks: {
    Progress: {
      chain: Object.fromEntries(activeChains.map((c) => [c.key, { startBlock: "latest" as const, interval: 1 }])),
    },
    // Reads every Hub asset, Spoke slice, market and account once an hour of block time, from Avana's deployment on,
    // for the chart series (src/handlers/series.ts).
    SeriesSampler: { chain: samplerSource() },
  },
});
