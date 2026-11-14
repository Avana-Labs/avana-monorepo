// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A schema-valid release manifest for the tests.

import type { ReleaseManifest } from "../../src/manifest/index.ts";

export const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as `0x${string}`;
export const H = (n: number) => `0x${n.toString(16).padStart(64, "0")}` as `0x${string}`;
const imm = (n: number) => ({ address: A(n), codeHash: H(n), startBlock: 1, artifact: "Lock.sol:Lock" });
const upg = (n: number) => ({
  address: A(n),
  codeHash: H(n),
  implementation: A(n + 1000),
  implementationCodeHash: H(n + 1000),
  implementationArtifact: "AaveAdapter.sol:AaveAdapter",
  logics: [{ name: "AaveAdapterUserLogic", address: A(n + 2000), codeHash: H(n + 2000), artifact: "AaveAdapterUserLogic.sol:AaveAdapterUserLogic" }],
  startBlock: 1,
});

export function sampleManifest(): ReleaseManifest {
  return {
    schemaVersion: 1,
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
      aaveAdapter: upg(10),
      lpVaultSwap: upg(11),
      marketRegistry: upg(12),
      parameterStore: upg(13),
      riskModule: upg(14),
      timelock: imm(20),
      proxyManager: imm(21),
      collateralization: imm(22),
      vaultTokenFactory: imm(23),
      payoutEscrow: imm(24),
      lock: imm(25),
      lens: imm(26),
      lensModules: [imm(27)],
      lensAaveSizing: imm(28),
      flashSource: imm(29),
      flashLiquidator: imm(30),
      operatorHelpers: [{ ...imm(31), signer: A(32), fundingSafe: A(33) }],
      lpVaults: [{ ...imm(34), integrationId: 1, kind: "uniswap-v3" }],
      firstLossReserves: [],
      daoDeficitOffsets: [],
      debtOracleImplementation: imm(35),
      clOracles: [],
      proxyCreationCodeHash: H(36),
    },
    markets: [],
    debtReserves: [],
    aave: {
      hubs: [{ ...upg(40), label: "stable", tier: 1 }],
      borrowSpokes: [{ ...upg(41), label: "uniV3Stable" }],
      lendSpokes: [{ ...upg(42), label: "lendStable" }],
      v3Pool: upg(43),
      accessManager: A(44),
    },
    roles: {
      timelock: { proposers: [A(50), A(51)], executors: [A(50)], cancellers: [A(50)], daoCancellers: [A(51)], normalDelay: 432000, publicExecution: true },
      governanceSafe: A(50),
      emergencyGuardian: A(52),
      aaveProtocolGuardian: A(53),
      aaveGovernanceExecutor: A(51),
      jointConfigSafe: A(54),
      marketRegistryGuardians: [A(52)],
      parameterStorePauseGuardians: [A(52)],
      riskStewards: [A(54)],
      keepers: [A(55)],
    },
    external: [{ name: "USDC", group: "token", address: A(60), codeHash: H(60), implementation: null, standIn: true }],
  };
}
