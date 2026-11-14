// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The address view of a release manifest that the web app and scripts import: every Avana contract a user action or a
// read goes to, the markets, debt reserves and Aave V4 Spokes and Hubs, without code hashes, roles or third-party
// checks. scripts/generate-addresses.mjs applies it to every verified manifest; nothing here is written by hand per chain.

import type { Address, Hex } from "viem";
import type { ReleaseManifest } from "../manifest/types.ts";

export interface AvanaAddresses {
  readonly chainId: number;
  readonly network: string;
  readonly release: string;
  readonly commit: string;
  readonly abiHash: Hex;
  /** Lowest deployment block of the Avana contracts; where an event scan starts. */
  readonly startBlock: number;
  readonly contracts: {
    readonly aaveAdapter: Address;
    readonly lpVaultSwap: Address;
    readonly marketRegistry: Address;
    readonly parameterStore: Address;
    readonly riskModule: Address;
    readonly timelock: Address;
    readonly proxyManager: Address;
    readonly collateralization: Address;
    readonly vaultTokenFactory: Address;
    readonly payoutEscrow: Address;
    readonly lock: Address;
    readonly lens: Address;
    readonly flashSource: Address;
    readonly flashLiquidator: Address;
  };
  readonly lpVaults: readonly { readonly integrationId: number; readonly kind: string; readonly address: Address }[];
  readonly markets: readonly {
    readonly marketId: string;
    readonly integrationId: number;
    readonly spoke: Address;
    readonly reserveId: string;
    readonly vaultToken: Address;
    readonly lpOracle: Address;
    readonly pool: Address;
    readonly tokens: readonly Address[];
  }[];
  readonly debtReserves: readonly {
    readonly spoke: Address;
    readonly debtReserveId: string;
    readonly asset: Address;
    readonly decimals: number;
    readonly isGho: boolean;
    readonly debtOracle: Address | null;
  }[];
  readonly aave: {
    readonly hubs: readonly { readonly label: string; readonly tier: number; readonly address: Address }[];
    readonly borrowSpokes: readonly { readonly label: string; readonly address: Address }[];
    readonly lendSpokes: readonly { readonly label: string; readonly address: Address }[];
    readonly v3Pool: Address;
  };
}

/** The address view of one manifest. */
export function addressesFromManifest(m: ReleaseManifest): AvanaAddresses {
  const a = m.avana;
  const core = [a.aaveAdapter, a.lpVaultSwap, a.marketRegistry, a.parameterStore, a.riskModule, a.timelock, a.proxyManager, a.collateralization, a.vaultTokenFactory, a.payoutEscrow, a.lock, a.lens, a.flashSource, a.flashLiquidator];
  return {
    chainId: m.chainId,
    network: m.network,
    release: m.release,
    commit: m.commit,
    abiHash: m.abiHash,
    startBlock: Math.min(...core.map((c) => c.startBlock)),
    contracts: {
      aaveAdapter: a.aaveAdapter.address,
      lpVaultSwap: a.lpVaultSwap.address,
      marketRegistry: a.marketRegistry.address,
      parameterStore: a.parameterStore.address,
      riskModule: a.riskModule.address,
      timelock: a.timelock.address,
      proxyManager: a.proxyManager.address,
      collateralization: a.collateralization.address,
      vaultTokenFactory: a.vaultTokenFactory.address,
      payoutEscrow: a.payoutEscrow.address,
      lock: a.lock.address,
      lens: a.lens.address,
      flashSource: a.flashSource.address,
      flashLiquidator: a.flashLiquidator.address,
    },
    lpVaults: a.lpVaults.map((v) => ({ integrationId: v.integrationId, kind: v.kind, address: v.address })),
    markets: m.markets.map((k) => ({
      marketId: k.marketId,
      integrationId: k.integrationId,
      spoke: k.spoke,
      reserveId: k.reserveId,
      vaultToken: k.vaultToken.address,
      lpOracle: k.lpOracle.address,
      pool: k.pool,
      tokens: [...k.tokens],
    })),
    debtReserves: m.debtReserves.map((r) => ({
      spoke: r.spoke,
      debtReserveId: r.debtReserveId,
      asset: r.asset,
      decimals: r.decimals,
      isGho: r.isGho,
      debtOracle: r.debtOracle?.address ?? null,
    })),
    aave: {
      hubs: m.aave.hubs.map((h) => ({ label: h.label, tier: h.tier, address: h.address })),
      borrowSpokes: m.aave.borrowSpokes.map((s) => ({ label: s.label, address: s.address })),
      lendSpokes: m.aave.lendSpokes.map((s) => ({ label: s.label, address: s.address })),
      v3Pool: m.aave.v3Pool.address,
    },
  };
}

/** Orders release tags by version: `v1.10.0` after `v1.9.0`, a pre-release before its release. */
export function compareReleases(x: string, y: string): number {
  const parse = (t: string) => {
    const [core, pre] = t.replace(/^v/, "").split(/-(.*)/s);
    return { nums: core!.split(".").map(Number), pre: pre ?? null };
  };
  const a = parse(x);
  const b = parse(y);
  for (let i = 0; i < 3; i++) if (a.nums[i] !== b.nums[i]) return a.nums[i]! - b.nums[i]!;
  if (a.pre === b.pre) return 0;
  if (a.pre === null) return 1;
  if (b.pre === null) return -1;
  const pa = a.pre.split(".");
  const pb = b.pre.split(".");
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    if (pa[i] === undefined) return -1;
    if (pb[i] === undefined) return 1;
    const na = /^\d+$/.test(pa[i]!) ? Number(pa[i]) : NaN;
    const nb = /^\d+$/.test(pb[i]!) ? Number(pb[i]) : NaN;
    if (!Number.isNaN(na) && !Number.isNaN(nb)) {
      if (na !== nb) return na - nb;
    } else if (pa[i] !== pb[i]) return pa[i]! < pb[i]! ? -1 : 1;
  }
  return 0;
}
