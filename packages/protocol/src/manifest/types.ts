// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Release manifest of one Avana deployment on one chain: every address with its code hash and deployment block, the
// core stack of each AMM integration, the markets (two per pool: Full range and Custom range), the debt reserves and
// their loss layers, the governance addresses and the third-party contracts the deployment names. It is produced from
// what the step 9 deploy scripts write (deployments-local/<network>/avana.json, markets.json, coverage.json) plus the
// chain. The services read the subset in services/common/src/manifest.ts; this file is the full shape, checked by
// schema.ts.

import type { Address, Hex } from "viem";

export const MANIFEST_SCHEMA_VERSION = 2;

/** A contract: `codeHash = keccak256(runtime code)`. Avana's core contracts are not upgradeable. */
export interface Immutable {
  readonly address: Address;
  readonly codeHash: Hex;
  /** Block of the deployment transaction; the indexer's start block. */
  readonly startBlock: number;
  /** Artifact `<File>.sol:<Contract>` the runtime code is compared with (TEST-134); null for third-party code. */
  readonly artifact: string | null;
}

/** A third-party ERC-1967 proxy (Aave V4 Hubs and Spokes, the Aave V3 Pool) with its current implementation. */
export interface Upgradeable {
  readonly address: Address;
  readonly codeHash: Hex;
  readonly implementation: Address;
  readonly implementationCodeHash: Hex;
  readonly startBlock: number;
}

/**
 * One AMM integration's core stack (`03_DeployAvana`): its LPVault, and the RiskModule, LiquidationModule,
 * AaveAdapter and FlashloanRepay bound to that LPVault (`RiskModule.LP_VAULT` is immutable).
 */
export interface Integration {
  readonly integrationId: number;
  /** "uniswap-v3", "slipstream" or "uniswap-v4". */
  readonly kind: string;
  readonly lpVault: Immutable;
  readonly riskModule: Immutable;
  readonly liquidationModule: Immutable;
  readonly aaveAdapter: Immutable;
  readonly flashloanRepay: Immutable;
}

/** An operator flash liquidator (liquidator/): callable only by its `OPERATOR`, the liquidation bot's keystore. */
export interface FlashLiquidator extends Immutable {
  readonly integrationId: number;
  readonly operator: Address;
}

/** `IRiskModule.MarketKind`. */
export type MarketKind = "full-range" | "custom-range";

export interface Market {
  readonly marketId: string;
  /** The listing's name, `<pool> full` or `<pool> custom`. */
  readonly name: string;
  /** Selects the market's core stack in `avana.integrations`. */
  readonly integrationId: number;
  readonly kind: MarketKind;
  /** The pool key the LPVault binds the market to (bytes32: a v3/Slipstream pool address left-padded, or a v4 PoolId). */
  readonly pool: Hex;
  readonly spoke: Address;
  readonly hub: Address;
  readonly vaultToken: Immutable;
  /** The market's LPOracle, the Spoke's price source for the vault token. */
  readonly lpOracle: Immutable;
  /** The vault token's reserve on the Spoke. */
  readonly reserveId: string;
  readonly tokens: readonly [Address, Address];
  /** The band, fixed for life: the full-range ticks for a Full range market, the Custom width around the listing tick otherwise. */
  readonly bandLower: number;
  readonly bandUpper: number;
  /** Equal for both markets of a pool. */
  readonly ltvBps: number;
  readonly unitDecimals: number;
  /** Every Chainlink leg of both tokens' price routes (`LPOracle.feedsOf`); the monitor reads their ages. */
  readonly feeds: readonly { readonly feed: Address; readonly heartbeatSeconds: number }[];
}

export interface DebtReserve {
  readonly spoke: Address;
  readonly debtReserveId: string;
  readonly asset: Address;
  readonly decimals: number;
  readonly isGho: boolean;
  /** The First-Loss Reserve the RiskModule registered for this reserve (`getDebtReserve`). */
  readonly firstLossReserve: Address;
  readonly feeds: readonly { readonly feed: Address; readonly heartbeatSeconds: number }[];
}

/** A loss layer of one (Hub, debt asset) (`07_DeployFirstLossReserves`, coverage.json). */
export interface LossLayer extends Immutable {
  readonly hub: Address;
  readonly hubLabel: string;
  readonly asset: Address;
  readonly symbol: string;
  readonly minimum: string;
}

/** A third-party contract the deployment names: Aave V4, Uniswap v3 and v4, Aerodrome Slipstream, tokens, feeds. */
export interface External {
  readonly name: string;
  /** "aave-v4" | "aave-v3" | "uniswap-v3" | "uniswap-v4" | "slipstream" | "token" | "feed" | "safe". */
  readonly group: string;
  readonly address: Address;
  readonly codeHash: Hex;
  /** ERC-1967 implementation when the contract is a proxy, else null. */
  readonly implementation: Address | null;
  /** True for a test-network stand-in (a contract Avana deploys in place of the real third-party one). */
  readonly standIn: boolean;
}

export interface RoleTable {
  /** Admin of the Avana AccessManager (the deployer renounces at deployment). */
  readonly aaveGovernanceExecutor: Address;
  readonly governanceSafe: Address;
  readonly emergencyGuardian: Address;
  readonly aaveProtocolGuardian: Address;
  readonly jointConfigSafe: Address;
  /** The liquidation bots registered in every RiskModule's keeper registry; borrowing stops while none is. */
  readonly keepers: readonly Address[];
  /**
   * The keeper top-up wallet and its refill rule (`11_FundKeepers`): a keeper signer below `minBalanceWei` is refilled
   * to `targetBalanceWei` from `wallet` (deploy config `keeperTopUp`, or `KEEPER_TOPUP_WALLET`). Null on a local node
   * whose config names none.
   */
  readonly keeperTopUp: KeeperTopUp | null;
}

export interface KeeperTopUp {
  readonly wallet: Address;
  readonly minBalanceWei: string;
  readonly targetBalanceWei: string;
}

export interface ReleaseManifest {
  readonly schemaVersion: 2;
  readonly chainId: number;
  /** anvil | sepolia | base-sepolia | ethereum | base. */
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
    /** The chain's Avana AccessManager (OpenZeppelin), authority of every core contract. */
    readonly accessManager: Immutable;
    readonly integrations: readonly Integration[];
    readonly flashLiquidators: readonly FlashLiquidator[];
  };
  readonly markets: readonly Market[];
  readonly debtReserves: readonly DebtReserve[];
  readonly coverage: {
    /** Avana's First-Loss Reserves, one per (Hub, debt asset). */
    readonly firstLossReserves: readonly LossLayer[];
    /** The Aave DAO's deficit offsets behind them. */
    readonly daoDeficitOffsets: readonly LossLayer[];
  };
  readonly aave: {
    readonly hubs: readonly (Upgradeable & { readonly label: string; readonly tier: number })[];
    readonly borrowSpokes: readonly (Upgradeable & { readonly label: string })[];
    readonly lendSpokes: readonly (Upgradeable & { readonly label: string })[];
    readonly v3Pool: Upgradeable;
    readonly accessManager: Address;
  };
  readonly roles: RoleTable;
  readonly external: readonly External[];
  /** The chain's Uniswap v4 PoolManager (third-party, `artifact` null); present only with a Uniswap v4 integration. */
  readonly uniswapV4?: { readonly poolManager: Immutable };
}
