// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The address view of a release manifest that the web app and scripts import: every Avana contract a user action or a
// read goes to, the markets, debt reserves and Aave V4 Spokes and Hubs, without code hashes, roles or third-party
// checks. scripts/generate-addresses.mjs applies it to every verified manifest; nothing here is written by hand per chain.

import type { Address, Hex } from "viem";
import type { MarketKind, ReleaseManifest } from "../manifest/types.ts";

export interface AvanaAddresses {
  readonly chainId: number;
  readonly network: string;
  readonly release: string;
  readonly commit: string;
  readonly abiHash: Hex;
  /** Lowest deployment block of the Avana contracts; where an event scan starts. */
  readonly startBlock: number;
  readonly accessManager: Address;
  /** One core stack per AMM integration. */
  readonly integrations: readonly {
    readonly integrationId: number;
    readonly kind: string;
    readonly lpVault: Address;
    readonly riskModule: Address;
    readonly liquidationModule: Address;
    readonly aaveAdapter: Address;
    readonly flashloanRepay: Address;
  }[];
  readonly flashLiquidators: readonly { readonly integrationId: number; readonly address: Address; readonly operator: Address }[];
  /** Two per pool: Full range and Custom range. */
  readonly markets: readonly {
    readonly marketId: string;
    readonly name: string;
    readonly integrationId: number;
    readonly kind: MarketKind;
    readonly pool: Hex;
    readonly spoke: Address;
    readonly reserveId: string;
    readonly vaultToken: Address;
    readonly lpOracle: Address;
    readonly tokens: readonly Address[];
    readonly bandLower: number;
    readonly bandUpper: number;
    readonly ltvBps: number;
  }[];
  readonly debtReserves: readonly {
    readonly spoke: Address;
    readonly debtReserveId: string;
    readonly asset: Address;
    readonly decimals: number;
    readonly isGho: boolean;
    readonly firstLossReserve: Address;
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
  const core = a.integrations.flatMap((x) => [x.lpVault, x.riskModule, x.liquidationModule, x.aaveAdapter, x.flashloanRepay]);
  return {
    chainId: m.chainId,
    network: m.network,
    release: m.release,
    commit: m.commit,
    abiHash: m.abiHash,
    startBlock: Math.min(a.accessManager.startBlock, ...core.map((c) => c.startBlock)),
    accessManager: a.accessManager.address,
    integrations: a.integrations.map((x) => ({
      integrationId: x.integrationId,
      kind: x.kind,
      lpVault: x.lpVault.address,
      riskModule: x.riskModule.address,
      liquidationModule: x.liquidationModule.address,
      aaveAdapter: x.aaveAdapter.address,
      flashloanRepay: x.flashloanRepay.address,
    })),
    flashLiquidators: a.flashLiquidators.map((f) => ({ integrationId: f.integrationId, address: f.address, operator: f.operator })),
    markets: m.markets.map((k) => ({
      marketId: k.marketId,
      name: k.name,
      integrationId: k.integrationId,
      kind: k.kind,
      pool: k.pool,
      spoke: k.spoke,
      reserveId: k.reserveId,
      vaultToken: k.vaultToken.address,
      lpOracle: k.lpOracle.address,
      tokens: [...k.tokens],
      bandLower: k.bandLower,
      bandUpper: k.bandUpper,
      ltvBps: k.ltvBps,
    })),
    debtReserves: m.debtReserves.map((r) => ({
      spoke: r.spoke,
      debtReserveId: r.debtReserveId,
      asset: r.asset,
      decimals: r.decimals,
      isGho: r.isGho,
      firstLossReserve: r.firstLossReserve,
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
