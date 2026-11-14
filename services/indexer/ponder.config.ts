// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Ponder configuration: Ethereum and Base, or Sepolia and Base Sepolia (INDEXER_NETWORK_SET), from the verified
// manifests named in AVANA_MANIFEST. EVENTS.md lists every event each source is indexed for.

import { createConfig } from "ponder";
import { abis } from "./src/config/abis.ts";
import { clPoolAbi } from "@avana/services-common/views";
import {
  activeChains,
  ammPoolSource,
  chainSources,
  firstLossReserveSource,
  debtOracleSource,
  hubRecordedSource,
  hubSource,
  lpOracleSource,
  perChain,
  samplerSource,
  spokeAddedSource,
  spokeApprovedSource,
  spokeSource,
  vaultTokenSource,
} from "./src/config/sources.ts";

const a = (x: { address: `0x${string}`; startBlock: number }) => ({ address: x.address, startBlock: x.startBlock });

export default createConfig({
  ordering: "multichain",
  // PostgreSQL in production and on the test networks; the embedded PGlite store only for the local anvil
  // rehearsal (INDEXER_NETWORK_SET=local), so the end-to-end run needs no database server.
  database: process.env.INDEXER_NETWORK_SET === "local" ? { kind: "pglite", directory: ".ponder/pglite" } : { kind: "postgres" },
  chains: chainSources(),
  contracts: {
    AaveAdapter: { abi: abis.AaveAdapter, chain: perChain((m) => a(m.avana.aaveAdapter)) },
    ProxyManager: { abi: abis.ProxyManager, chain: perChain((m) => a(m.avana.proxyManager)) },
    Collateralization: { abi: abis.Collateralization, chain: perChain((m) => a(m.avana.collateralization)) },
    LPVaultSwap: { abi: abis.LPVaultSwap, chain: perChain((m) => a(m.avana.lpVaultSwap)) },
    PayoutEscrow: { abi: abis.PayoutEscrow, chain: perChain((m) => a(m.avana.payoutEscrow)) },
    MarketRegistry: { abi: abis.MarketRegistry, chain: perChain((m) => a(m.avana.marketRegistry)) },
    ParameterStore: { abi: abis.ParameterStore, chain: perChain((m) => a(m.avana.parameterStore)) },
    RiskModule: { abi: abis.RiskModule, chain: perChain((m) => a(m.avana.riskModule)) },
    AvanaTimelock: { abi: abis.AvanaTimelock, chain: perChain((m) => a(m.avana.timelock)) },
    VaultTokenFactory: { abi: abis.VaultTokenFactory, chain: perChain((m) => a(m.avana.vaultTokenFactory)) },
    LPVault: {
      abi: abis.LPVault,
      chain: perChain((m) => ({
        address: m.avana.lpVaults.map((v) => v.address),
        startBlock: Math.min(...m.avana.lpVaults.map((v) => v.startBlock)),
      })),
    },
    FlashLiquidator: {
      abi: abis.FlashLiquidator,
      chain: perChain((m) => {
        const helpers = [m.avana.flashLiquidator, ...m.avana.operatorHelpers];
        return { address: helpers.map((h) => h.address), startBlock: Math.min(...helpers.map((h) => h.startBlock)) };
      }),
    },
    VaultToken: { abi: abis.VaultToken, chain: vaultTokenSource() },
    LPOracle: { abi: abis.LPOracle, chain: lpOracleSource() },
    DebtOracle: { abi: abis.DebtOracle, chain: debtOracleSource() },
    AvanaFirstLossReserve: { abi: abis.AvanaFirstLossReserve, chain: firstLossReserveSource() },
    // Aave V4: every Hub and every Lend and CDP Spoke, the manifest's and those listed later (src/config/aaveSources.ts).
    // Spoke events are attributed only to accounts the AaveAdapter and the ProxyManager both announced (TEST-144).
    AaveSpoke: { abi: abis.AaveSpoke, chain: spokeSource() },
    AaveSpokeAdded: { abi: abis.AaveSpoke, chain: spokeAddedSource() },
    AaveSpokeApproved: { abi: abis.AaveSpoke, chain: spokeApprovedSource() },
    AaveHub: { abi: abis.AaveHub, chain: hubSource() },
    AaveHubRecorded: { abi: abis.AaveHub, chain: hubRecordedSource() },
    // The AMM pool of every listed market, for its volume, fee and price series.
    AmmPool: { abi: clPoolAbi, chain: ammPoolSource() },
  },
  // One row per chain records the last block handled at the realtime head; the export never serves past it.
  blocks: {
    Progress: {
      chain: Object.fromEntries(activeChains.map((c) => [c.key, { startBlock: "latest" as const, interval: 1 }])),
    },
    // Reads every Hub asset, Spoke slice, market and account once an hour of block time, from the Lens deployment on,
    // for the chart series (src/handlers/series.ts).
    SeriesSampler: { chain: samplerSource() },
  },
});
