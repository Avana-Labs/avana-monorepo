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
    /** One Coverage Spoke per covered debt asset. */
    readonly coverageSpokes: readonly (Immutable & { readonly asset: Address })[];
    /** `PROXY_CREATION_CODE_HASH` of the ProxyManager; proxies are attributed only if their CREATE2 address matches. */
    readonly proxyCreationCodeHash: Hex;
  };
  readonly markets: readonly ManifestMarket[];
  readonly debtReserves: readonly ManifestDebtReserve[];
  readonly aave: {
    readonly hub: Upgradeable;
    readonly borrowSpokes: readonly Upgradeable[];
    readonly lendSpoke: Upgradeable;
    /** The Aave V3 Pool the helper flash-borrows every debt asset from, GHO included; its only lender. */
    readonly v3Pool: Upgradeable;
  };
  /** Chainlink sequencer-uptime feed on an L2, null on Ethereum. */
  readonly sequencerFeed: Address | null;
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

/** Manifests store uint256 values as decimal strings; IDs named *Id parse to bigint. */
function reviveBigInt(key: string, value: unknown): unknown {
  if ((key === "marketId" || key === "reserveId" || key === "debtReserveId") && typeof value === "string") {
    if (!/^\d+$/.test(value)) throw new Error(`manifest field ${key} is not a decimal string`);
    return BigInt(value);
  }
  return value;
}
