// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The part of a verified release manifest (contracts/deployments/verified/) that the indexer, the bot runner, the monitor, the
// faucet and Convex read.
// The full schema belongs to packages/protocol; this view names only the fields the services use, so a field
// the services rely on cannot disappear from the schema without a type error here.

import { readFileSync } from "node:fs";
import { validate } from "@avana/protocol/manifest/schema";
import type { Address, Hex } from "viem";

/** A contract the services call or index, with the block of its deployment receipt (the indexer's start block). */
export interface Deployed {
  readonly address: Address;
  readonly startBlock: number;
}

/** A third-party ERC-1967 proxy (Aave V4 Hubs and Spokes, the Aave V3 Pool). */
export interface Upgradeable extends Deployed {
  readonly implementation: Address;
}

/** A contract with its runtime code hash. Avana's core contracts are not upgradeable. */
export interface Immutable extends Deployed {
  readonly codeHash: Hex;
}

/** One AMM integration's core stack: the LPVault and the RiskModule, LiquidationModule, AaveAdapter and FlashloanRepay bound to it. */
export interface ManifestIntegration {
  readonly integrationId: number;
  readonly kind: string;
  readonly lpVault: Immutable;
  readonly riskModule: Immutable;
  readonly liquidationModule: Immutable;
  readonly aaveAdapter: Immutable;
  readonly flashloanRepay: Immutable;
}

export interface ServiceManifest {
  readonly chainId: number;
  /** Release tag vX.Y.Z of the deployed commit. */
  readonly release: string;
  /** Hash of the ABIs in the release build; every service refuses to run on a mismatch (TEST-149). */
  readonly abiHash: Hex;
  readonly avana: {
    readonly accessManager: Immutable;
    readonly integrations: readonly ManifestIntegration[];
    /** Operator flash liquidators, each callable only by its operator (the liquidation bot's keystore). */
    readonly flashLiquidators: readonly (Immutable & { readonly integrationId: number; readonly operator: Address })[];
  };
  readonly markets: readonly ManifestMarket[];
  readonly debtReserves: readonly ManifestDebtReserve[];
  readonly coverage: {
    /** One First-Loss Reserve per (Hub, debt asset). */
    readonly firstLossReserves: readonly LossLayer[];
    /** The Aave DAO's deficit offset behind each First-Loss Reserve. */
    readonly daoDeficitOffsets: readonly LossLayer[];
  };
  readonly aave: {
    /** Every Aave V4 Hub of the deployment, with its label and risk tier (1 to 3). */
    readonly hubs: readonly ManifestHub[];
    /** Every CDP Spoke (Borrow Spoke), whichever Hub it draws from. */
    readonly borrowSpokes: readonly Upgradeable[];
    /** Every Lend Spoke: an Aave standard Spoke, supply only, on one Hub. */
    readonly lendSpokes: readonly ManifestLendSpoke[];
    /** The Aave V3 Pool the flash liquidators and FlashloanRepay borrow from. */
    readonly v3Pool: Upgradeable;
  };
  readonly roles: {
    /** The liquidation bots registered in the RiskModules' keeper registry. */
    readonly keepers: readonly Address[];
    /** The keeper top-up wallet and its refill rule (`11_FundKeepers`); null when the deploy config names none. */
    readonly keeperTopUp: { readonly wallet: Address; readonly minBalanceWei: string; readonly targetBalanceWei: string } | null;
  };
  /** Chainlink sequencer-uptime feed on an L2, null on Ethereum. */
  readonly sequencerFeed: Address | null;
  /** The chain's Uniswap v4 PoolManager; absent on a chain without a v4 integration. */
  readonly uniswapV4?: { readonly poolManager: Deployed };
}

/** A loss layer of one (Hub, debt asset). */
export interface LossLayer extends Immutable {
  readonly hub: Address;
  readonly hubLabel: string;
  readonly asset: Address;
  readonly symbol: string;
}

/** An Aave V4 Hub with the label the app shows and its risk tier. */
export interface ManifestHub extends Upgradeable {
  readonly label: string;
  readonly tier: number;
}

export interface ManifestLendSpoke extends Upgradeable {
  readonly label: string;
}

export type MarketKind = "full-range" | "custom-range";

export interface ManifestMarket {
  readonly marketId: bigint;
  readonly name: string;
  /** Selects the market's core stack in `avana.integrations`. */
  readonly integrationId: number;
  /** Each pool has two markets: Full range (exact full-range ticks) and Custom range (positions inside the band). */
  readonly kind: MarketKind;
  /** The bytes32 pool key (a v3/Slipstream pool address left-padded, or a v4 PoolId). */
  readonly pool: Hex;
  readonly spoke: Address;
  readonly hub: Address;
  readonly vaultToken: Immutable;
  readonly lpOracle: Immutable;
  readonly reserveId: bigint;
  readonly tokens: readonly [Address, Address];
  /** The band, fixed for life. */
  readonly bandLower: number;
  readonly bandUpper: number;
  /** The same for both markets of a pool. */
  readonly ltvBps: number;
  readonly unitDecimals: number;
  /** Every Chainlink leg of both tokens' price routes; the monitor reads their ages. */
  readonly feeds: readonly { readonly feed: Address; readonly heartbeatSeconds: number }[];
}

export interface ManifestDebtReserve {
  readonly spoke: Address;
  readonly debtReserveId: bigint;
  readonly asset: Address;
  readonly decimals: number;
  readonly isGho: boolean;
  readonly firstLossReserve: Address;
  readonly feeds: readonly { readonly feed: Address; readonly heartbeatSeconds: number }[];
}

/** The core stack a market belongs to; throws when the manifest lists none. */
export function integrationOf(m: Pick<ServiceManifest, "avana">, integrationId: number): ManifestIntegration {
  const x = m.avana.integrations.find((i) => i.integrationId === integrationId);
  if (!x) throw new Error(`manifest lists no integration ${integrationId}`);
  return x;
}

/**
 * Loads one chain's verified manifest, refuses it unless it matches the release manifest schema of packages/protocol
 * (every error listed), and checks it against the ABI hash compiled into the service.
 * `expectedAbiHash` comes from packages/protocol's generated ABIs, never from the manifest itself.
 */
export function loadManifest(path: string, expectedAbiHash: Hex): ServiceManifest {
  const text = readFileSync(path, "utf8");
  const errors = validate(JSON.parse(text));
  if (errors.length > 0) {
    const list = errors.map((e) => `  ${e.path}: ${e.message}`).join("\n");
    throw new Error(`manifest ${path} does not match the release manifest schema:\n${list}`);
  }
  const manifest = JSON.parse(text, reviveBigInt) as ServiceManifest;
  if (manifest.abiHash.toLowerCase() !== expectedAbiHash.toLowerCase()) {
    throw new Error(`manifest ${path} has ABI hash ${manifest.abiHash}, the service was built for ${expectedAbiHash}`);
  }
  return manifest;
}

/** The Hubs and Spokes of one manifest, lower-case, checked to be present and distinct. */
export interface AaveTopology {
  readonly hubs: readonly { readonly address: Address; readonly label: string; readonly tier: number; readonly startBlock: number }[];
  readonly lendSpokes: readonly { readonly address: Address; readonly label: string; readonly startBlock: number }[];
  readonly borrowSpokes: readonly { readonly address: Address; readonly startBlock: number }[];
}

/**
 * Reads `aave.hubs`, `aave.lendSpokes` and `aave.borrowSpokes`. A manifest without a Hub or a Lend Spoke, or naming
 * one address twice, is refused: the services would otherwise show a chain with no Lend page or count one Hub twice.
 */
export function aaveTopology(m: Pick<ServiceManifest, "chainId" | "aave">): AaveTopology {
  const lower = (a: string) => a.toLowerCase() as Address;
  const hubs = (m.aave.hubs ?? []).map((h) => ({ address: lower(h.address), label: h.label, tier: h.tier, startBlock: h.startBlock }));
  const lendSpokes = (m.aave.lendSpokes ?? []).map((s) => ({ address: lower(s.address), label: s.label, startBlock: s.startBlock }));
  const borrowSpokes = (m.aave.borrowSpokes ?? []).map((s) => ({ address: lower(s.address), startBlock: s.startBlock }));
  if (hubs.length === 0) throw new Error(`manifest of chain ${m.chainId} lists no Hub in aave.hubs`);
  if (lendSpokes.length === 0) throw new Error(`manifest of chain ${m.chainId} lists no Lend Spoke in aave.lendSpokes`);
  const all = [...hubs, ...lendSpokes, ...borrowSpokes].map((x) => x.address);
  const twice = all.find((a, i) => all.indexOf(a) !== i);
  if (twice) throw new Error(`manifest of chain ${m.chainId} names ${twice} twice among its Hubs and Spokes`);
  return { hubs, lendSpokes, borrowSpokes };
}

/** The manifest's Uniswap v4 PoolManager, address in lower case, or null when it names none. */
export function uniswapV4PoolManager(m: Pick<ServiceManifest, "uniswapV4">): Deployed | null {
  const pm = m.uniswapV4?.poolManager;
  return pm ? { address: pm.address.toLowerCase() as Address, startBlock: pm.startBlock } : null;
}

/** Manifests store uint256 values as decimal strings; IDs named *Id parse to bigint. */
function reviveBigInt(key: string, value: unknown): unknown {
  if ((key === "marketId" || key === "reserveId" || key === "debtReserveId") && typeof value === "string") {
    if (!/^\d+$/.test(value)) throw new Error(`manifest field ${key} is not a decimal string`);
    return BigInt(value);
  }
  return value;
}
