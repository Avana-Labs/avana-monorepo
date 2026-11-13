// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Release manifest of one Avana deployment on one chain: every address, its code hash, each proxy's implementation,
// the deployment blocks, the governance role table and the third-party contracts the deployment names. The services
// read the subset in services/common/src/manifest.ts; this file is the full shape, checked by schema.ts.

import type { Address, Hex } from "viem";

export const MANIFEST_SCHEMA_VERSION = 1;

/** An immutable contract (or a plain implementation): `codeHash = keccak256(runtime code)`. */
export interface Immutable {
  readonly address: Address;
  readonly codeHash: Hex;
  /** Block of the deployment transaction; the indexer's start block. */
  readonly startBlock: number;
  /** Artifact `<File>.sol:<Contract>` the runtime code is compared with (TEST-134); null for third-party code. */
  readonly artifact: string | null;
}

/** A logic contract an upgradeable router delegates to. */
export interface Logic {
  readonly name: string;
  readonly address: Address;
  readonly codeHash: Hex;
  readonly artifact: string;
}

/** An ERC-1967 proxy with its current implementation (Q-219: the keeper compares the slot with `implementation`). */
export interface Upgradeable {
  readonly address: Address;
  /** keccak256 of the proxy's own runtime code (OpenZeppelin ERC1967Proxy). */
  readonly codeHash: Hex;
  readonly implementation: Address;
  readonly implementationCodeHash: Hex;
  readonly implementationArtifact: string;
  readonly logics: readonly Logic[];
  readonly startBlock: number;
}

export interface OperatorHelper extends Immutable {
  readonly signer: Address;
  readonly fundingSafe: Address;
}

export interface LpVault extends Immutable {
  readonly integrationId: number;
  /** "uniswap-v3" or "slipstream". */
  readonly kind: string;
}

export interface CoverageSpoke extends Immutable {
  readonly asset: Address;
  readonly hub: Address;
}

/** The concentrated-liquidity LPOracle implementation an integration registers as its pricing, with its logic. */
export interface ClOracle extends Immutable {
  readonly integrationId: number;
  readonly moduleLogic: Immutable;
  readonly logics: readonly Logic[];
}

export interface Market {
  readonly marketId: string;
  readonly integrationId: number;
  readonly spoke: Address;
  readonly vaultToken: Immutable;
  readonly lpOracle: Upgradeable;
  readonly reserveId: string;
  readonly pool: Address;
  readonly tokens: readonly Address[];
  readonly feeds: readonly { readonly feed: Address; readonly heartbeatSeconds: number }[];
  readonly routes: readonly Immutable[];
}

export interface DebtReserve {
  readonly spoke: Address;
  readonly debtReserveId: string;
  readonly asset: Address;
  readonly decimals: number;
  readonly isGho: boolean;
  readonly debtOracle: Upgradeable | null;
  readonly feeds: readonly { readonly feed: Address; readonly heartbeatSeconds: number }[];
}

/** A third-party contract the deployment names: Aave V4, Uniswap v3, Aerodrome Slipstream, tokens, feeds. */
export interface External {
  readonly name: string;
  /** "aave-v4" | "aave-v3" | "uniswap-v3" | "slipstream" | "token" | "feed" | "safe". */
  readonly group: string;
  readonly address: Address;
  readonly codeHash: Hex;
  /** ERC-1967 implementation when the contract is a proxy, else null. */
  readonly implementation: Address | null;
  /** True for a test-network stand-in (a contract Avana deploys in place of the real third-party one). */
  readonly standIn: boolean;
}

export interface RoleTable {
  readonly timelock: {
    readonly proposers: readonly Address[];
    readonly executors: readonly Address[];
    readonly cancellers: readonly Address[];
    readonly daoCancellers: readonly Address[];
    readonly normalDelay: number;
    readonly publicExecution: boolean;
  };
  readonly governanceSafe: Address;
  readonly emergencyGuardian: Address;
  readonly aaveProtocolGuardian: Address;
  readonly aaveGovernanceExecutor: Address;
  readonly jointConfigSafe: Address;
  /** MarketRegistry APPLICATION_PAUSE_GUARDIAN and APPLICATION_FREEZE_GUARDIAN holders. */
  readonly marketRegistryGuardians: readonly Address[];
  /** ParameterStore APPLICATION_PAUSE_GUARDIAN holders. */
  readonly parameterStorePauseGuardians: readonly Address[];
  /** ParameterStore APPLICATION_RISK_STEWARD holders. */
  readonly riskStewards: readonly Address[];
  /** LPVaultSwap committed operators (keepers). */
  readonly keepers: readonly Address[];
}

export interface ReleaseManifest {
  readonly schemaVersion: 1;
  readonly chainId: number;
  /** anvil | sepolia | ethereum | base. */
  readonly network: string;
  /** Release tag vX.Y.Z (a `-local` or `-test` suffix marks a learning deployment that is never published). */
  readonly release: string;
  /** Git commit of the build. */
  readonly commit: string;
  readonly abiHash: Hex;
  readonly deployer: Address;
  readonly create3Factory: Address;
  readonly feeRecipient: Address;
  readonly sequencerFeed: Address | null;
  readonly avana: {
    readonly aaveAdapter: Upgradeable;
    readonly lpVaultSwap: Upgradeable;
    readonly marketRegistry: Upgradeable;
    readonly parameterStore: Upgradeable;
    readonly riskModule: Upgradeable;
    readonly timelock: Immutable;
    readonly proxyManager: Immutable;
    readonly collateralization: Immutable;
    readonly vaultTokenFactory: Immutable;
    readonly payoutEscrow: Immutable;
    readonly lock: Immutable;
    readonly lens: Immutable;
    readonly lensModules: readonly Immutable[];
    readonly lensAaveSizing: Immutable;
    readonly flashSource: Immutable;
    readonly flashLiquidator: Immutable;
    readonly operatorHelpers: readonly OperatorHelper[];
    readonly lpVaults: readonly LpVault[];
    readonly coverageSpokes: readonly CoverageSpoke[];
    /** The Aave DAO's deficit offset behind each Coverage Spoke (2.14), deployed on the Aave side. */
    readonly deficitOffsetSpokes: readonly CoverageSpoke[];
    readonly debtOracleImplementation: Immutable;
    /** Null while the concentrated-liquidity LPOracle implementation is not deployed. */
    readonly clOracles: readonly ClOracle[];
    readonly proxyCreationCodeHash: Hex;
  };
  readonly markets: readonly Market[];
  readonly debtReserves: readonly DebtReserve[];
  readonly aave: {
    readonly hubs: readonly (Upgradeable & { readonly label: string; readonly tier: number })[];
    readonly borrowSpokes: readonly (Upgradeable & { readonly label: string })[];
    readonly lendSpokes: readonly (Upgradeable & { readonly label: string })[];
    readonly v3Pool: Upgradeable;
    readonly accessManager: Address;
  };
  readonly roles: RoleTable;
  readonly external: readonly External[];
}
