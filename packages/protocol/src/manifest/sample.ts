// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A complete release manifest that passes the schema, for tests here and in the services (whose loadManifest
// validates every manifest against the schema): placeholder addresses and hashes, one integration with one pool's two
// markets (Full range and Custom range), one debt reserve and its First-Loss Reserve.

import type { ReleaseManifest } from "./types.ts";

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as `0x${string}`;
const H = (n: number) => `0x${n.toString(16).padStart(64, "0")}` as `0x${string}`;
const imm = (n: number, artifact: string | null = null) => ({ address: A(n), codeHash: H(n), startBlock: 1, artifact });
const upg = (n: number) => ({ address: A(n), codeHash: H(n), implementation: A(n + 1000), implementationCodeHash: H(n + 1000), startBlock: 1 });
/** A Uniswap v3 pool address as the bytes32 pool key the LPVault and the RiskModule use. */
const POOL = `0x${"0".repeat(24)}${A(70).slice(2)}` as `0x${string}`;
const market = (marketId: string, kind: "full-range" | "custom-range", n: number, bandLower: number, bandUpper: number) => ({
  marketId,
  name: `USDC-USDT-100 ${kind === "full-range" ? "full" : "custom"}`,
  integrationId: 1,
  kind,
  pool: POOL,
  spoke: A(41),
  hub: A(40),
  vaultToken: imm(n, "VaultToken.sol:VaultToken"),
  lpOracle: imm(n + 1, "LPOracle.sol:LPOracle"),
  reserveId: String(n),
  tokens: [A(60), A(61)] as [`0x${string}`, `0x${string}`],
  bandLower,
  bandUpper,
  ltvBps: 9000,
  unitDecimals: 18,
  feeds: [{ feed: A(62), heartbeatSeconds: 86400 }],
});

export function sampleManifest(): ReleaseManifest {
  return {
    schemaVersion: 2,
    chainId: 11155111,
    network: "sepolia",
    release: "v1.0.0",
    commit: "ff965db",
    abiHash: H(9),
    deployer: A(1),
    create3Factory: A(2),
    feeRecipient: A(3),
    sequencerFeed: null,
    avana: {
      accessManager: imm(20, "AccessManager.sol:AccessManager"),
      integrations: [
        {
          integrationId: 1,
          kind: "uniswap-v3",
          lpVault: imm(10, "UniswapV3Integration.sol:UniswapV3Integration"),
          riskModule: imm(11, "RiskModule.sol:RiskModule"),
          liquidationModule: imm(12, "LiquidationModule.sol:LiquidationModule"),
          aaveAdapter: imm(13, "AaveAdapter.sol:AaveAdapter"),
          flashloanRepay: imm(14, "FlashloanRepay.sol:FlashloanRepay"),
        },
      ],
      flashLiquidators: [{ ...imm(15, "liquidator:FlashLiquidator.sol:FlashLiquidator"), integrationId: 1, operator: A(55) }],
    },
    markets: [market("1", "full-range", 30, -887270, 887270), market("2", "custom-range", 32, -100, 100)],
    debtReserves: [{ spoke: A(41), debtReserveId: "1", asset: A(60), decimals: 6, isGho: false, firstLossReserve: A(35), feeds: [{ feed: A(62), heartbeatSeconds: 86400 }] }],
    coverage: {
      firstLossReserves: [{ ...imm(35, "FirstLossReserve.sol:FirstLossReserve"), hub: A(40), hubLabel: "stable", asset: A(60), symbol: "USDC", minimum: "1000000000" }],
      daoDeficitOffsets: [{ ...imm(36), hub: A(40), hubLabel: "stable", asset: A(60), symbol: "USDC", minimum: "1000000000" }],
    },
    aave: {
      hubs: [{ ...upg(40), label: "stable", tier: 1 }],
      borrowSpokes: [{ ...upg(41), label: "uniV3Stable" }],
      lendSpokes: [{ ...upg(42), label: "lendStable" }],
      v3Pool: upg(43),
      accessManager: A(44),
    },
    roles: {
      aaveGovernanceExecutor: A(51),
      governanceSafe: A(50),
      emergencyGuardian: A(52),
      aaveProtocolGuardian: A(53),
      jointConfigSafe: A(54),
      keepers: [A(55)],
      keeperTopUpWallet: A(56),
    },
    external: [{ name: "USDC", group: "token", address: A(60), codeHash: H(60), implementation: null, standIn: true }],
  };
}
