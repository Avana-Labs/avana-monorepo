// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The part of a verified release manifest (deployments/verified/) that the indexer and the keeper read.
// The full schema belongs to packages/protocol; this view names only the fields the services use, so a field
// the services rely on cannot disappear from the schema without a type error here.

import { readFileSync } from "node:fs";
import type { Address, Hex } from "viem";

/** A contract the services call or index, with the block of its deployment receipt (the indexer's start block). */
export interface Deployed {
  readonly address: Address;
  readonly startBlock: number;
}

/** An ERC-1967 proxy: the keeper's code check compares its implementation slot with `implementation` (Q-219). */
export interface Upgradeable extends Deployed {
  readonly implementation: Address;
}

/** An immutable contract: the keeper's code check compares `keccak256(runtime code)` with `codeHash`. */
export interface Immutable extends Deployed {
  readonly codeHash: Hex;
}

export interface ServiceManifest {
  readonly chainId: number;
  /** Release tag vX.Y.Z of the deployed commit. */
  readonly release: string;
  /** Hash of the ABIs in the release build; every service refuses to run on a mismatch (TEST-149). */
  readonly abiHash: Hex;
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
    /** The core flash source; it serves only `deleverage` (LIQ-081). */
    readonly flashSource: Immutable;
    /** The public flash liquidation helper (REQ-HELPER-015). */
    readonly flashLiquidator: Immutable;
    /** One operator helper per keeper instance, bound to that instance's signer and funding Safe (REQ-HELPER-011). */
    readonly operatorHelpers: readonly (Immutable & { readonly signer: Address; readonly fundingSafe: Address })[];
    /** One LPVault per AMM integration on this chain. */
    readonly lpVaults: readonly (Immutable & { readonly integrationId: number })[];
    /** One Coverage Spoke per (Hub, covered debt asset). */
    readonly coverageSpokes: readonly (Immutable & { readonly asset: Address; readonly hub: Address })[];
    /** `PROXY_CREATION_CODE_HASH` of the ProxyManager; proxies are attributed only if their CREATE2 address matches. */
    readonly proxyCreationCodeHash: Hex;
  };
  readonly markets: readonly ManifestMarket[];
  readonly debtReserves: readonly ManifestDebtReserve[];
  readonly aave: {
    /** Every Aave V4 Hub of the deployment, with its label and risk tier (1 to 3). */
    readonly hubs: readonly ManifestHub[];
    /** Every CDP Spoke (Borrow Spoke), whichever Hub it draws from. */
    readonly borrowSpokes: readonly Upgradeable[];
    /** Every Lend Spoke: an Aave standard Spoke, supply only, on one Hub. */
    readonly lendSpokes: readonly ManifestLendSpoke[];
    /** The Aave V3 Pool the helper flash-borrows every debt asset from, GHO included; its only lender. */
    readonly v3Pool: Upgradeable;
  };
  /** Chainlink sequencer-uptime feed on an L2, null on Ethereum. */
  readonly sequencerFeed: Address | null;
}

/** An Aave V4 Hub with the label the app shows and its risk tier (`MarketRegistry.hubTier`). */
export interface ManifestHub extends Upgradeable {
  readonly label: string;
  readonly tier: number;
}

export interface ManifestLendSpoke extends Upgradeable {
  readonly label: string;
}

export interface ManifestMarket {
  readonly marketId: bigint;
  /** Selects the market's LPVault in `avana.lpVaults`. */
  readonly integrationId: number;
  readonly spoke: Address;
  readonly vaultToken: Immutable;
  readonly lpOracle: Upgradeable;
  readonly reserveId: bigint;
  readonly pool: Address;
  readonly tokens: readonly Address[];
  /** Every Chainlink leg of both price routes; the keeper pokes on each new round and every heartbeat (EMG-035). */
  readonly feeds: readonly { readonly feed: Address; readonly heartbeatSeconds: number }[];
  /** Swap routes into each debt asset; the keeper code-checks them and keeps the flash loan off their reserves. */
  readonly routes: readonly Immutable[];
}

export interface ManifestDebtReserve {
  readonly spoke: Address;
  readonly debtReserveId: bigint;
  readonly asset: Address;
  readonly decimals: number;
  readonly isGho: boolean;
  /** Null for GHO, whose price is fixed by the Spoke. */
  readonly debtOracle: Upgradeable | null;
  /** Chainlink legs of the DebtOracle's routes; empty for GHO. */
  readonly feeds: readonly { readonly feed: Address; readonly heartbeatSeconds: number }[];
}

/**
 * Loads one chain's verified manifest and checks it against the ABI hash compiled into the service.
 * `expectedAbiHash` comes from packages/protocol's generated ABIs, never from the manifest itself.
 */
export function loadManifest(path: string, expectedAbiHash: Hex): ServiceManifest {
  const manifest = JSON.parse(readFileSync(path, "utf8"), reviveBigInt) as ServiceManifest;
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

/** Manifests store uint256 values as decimal strings; IDs named *Id parse to bigint. */
function reviveBigInt(key: string, value: unknown): unknown {
  if ((key === "marketId" || key === "reserveId" || key === "debtReserveId") && typeof value === "string") {
    if (!/^\d+$/.test(value)) throw new Error(`manifest field ${key} is not a decimal string`);
    return BigInt(value);
  }
  return value;
}
