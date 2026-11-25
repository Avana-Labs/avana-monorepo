// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Finds what one chain's snapshot reads, at the snapshot's block: the manifest's Hubs, each Hub asset with every Spoke
// the Hub lists for it, the manifest's CDP Spokes with their home Hubs, each asset's First-Loss Reserve and DAO deficit
// offset, and the Lend Spokes. The manifest's Lend Spokes are always read; on a Hub that none of them supplies, a Spoke
// is read as a Lend Spoke when it is shaped like one: not a CDP Spoke, not a loss layer, not the asset's fee receiver,
// active, with an add cap and no draw cap, and answering `getReserveCount`. A Hub or Spoke the manifest names that has
// no code yet at the block read (one a later release step adds) is left out.

import { hubViewsAbi, spokeViewsAbi } from "./abi.ts";
import { type ContractCall, type ViewClient, ZERO, all, lower, some, uniq } from "./client.ts";
import type { Address, ChainDeployment } from "./types.ts";

export interface DecodedSpokeData {
  drawnShares: bigint;
  premiumShares: bigint;
  addedShares: bigint;
  addCap: number | bigint;
  drawCap: number | bigint;
  active: boolean;
  halted: boolean;
  deficitRay: bigint;
}

export interface HubInfo {
  readonly hub: Address;
  readonly label: string;
  readonly tier: number;
  readonly assetCount: number;
}

/** One asset of one Hub with its configuration and every Spoke the Hub lists for it. */
export interface HubAssetInfo {
  readonly hub: Address;
  readonly assetId: bigint;
  readonly underlying: Address;
  readonly decimals: number;
  readonly feeReceiver: Address;
  readonly liquidityFeeBps: number;
  readonly irStrategy: Address;
  /** The manifest's First-Loss Reserve of (hub, underlying); the zero address when none covers it. */
  readonly firstLossReserve: Address;
  /** The manifest's DAO deficit offsets of (hub, underlying) that the Hub lists as Spokes of the asset. */
  readonly deficitOffsets: readonly Address[];
  readonly spokes: readonly { readonly spoke: Address; readonly data: DecodedSpokeData }[];
}

export interface Topology {
  readonly hubs: readonly HubInfo[];
  readonly cdpSpokes: readonly Address[];
  /** The manifest's home Hub of every CDP Spoke. */
  readonly homeHubOf: ReadonlyMap<Address, Address>;
  readonly coverage: ReadonlySet<Address>;
  /** The manifest's Lend Spokes in manifest order, then those found on later Hubs in address order. */
  readonly lendSpokes: readonly Address[];
  readonly assets: readonly HubAssetInfo[];
}

const hubCall = (hub: Address, functionName: string, args: readonly unknown[] = []): ContractCall => ({ address: hub, abi: hubViewsAbi, functionName, args });

/** Reads the Hubs, Spokes and Hub assets the snapshot covers. */
export async function discover(client: ViewClient, dep: ChainDeployment): Promise<Topology> {
  // 1. Which of the manifest's Hubs, CDP Spokes and Lend Spokes have code at this block.
  const manifestHubs = dep.hubs.map((h) => ({ ...h, address: lower(h.address) }));
  const cdpAll = uniq(dep.cdpSpokes.map((s) => lower(s.address)));
  const manifestLendAll = uniq(dep.lendSpokes.map(lower));
  const probed = await some(client, [
    ...manifestHubs.map((h) => hubCall(h.address, "getAssetCount")),
    ...cdpAll.map((sp): ContractCall => ({ address: sp, abi: spokeViewsAbi, functionName: "getLiquidationConfig", args: [] })),
    ...manifestLendAll.map((sp): ContractCall => ({ address: sp, abi: spokeViewsAbi, functionName: "getReserveCount", args: [] })),
  ]);
  const H = manifestHubs.length;
  const hubs: HubInfo[] = manifestHubs.flatMap((h, i) => (probed[i] === null ? [] : [{ hub: h.address, label: h.label, tier: h.tier, assetCount: Number(probed[i] as bigint) }]));
  const cdpSpokes = cdpAll.filter((_, i) => probed[H + i] !== null);
  const liveLend = new Set(manifestLendAll.filter((_, i) => probed[H + cdpAll.length + i] !== null));
  const homeHubOf = new Map(dep.cdpSpokes.map((s) => [lower(s.address), lower(s.hub)]));

  // 2. Each Hub asset's underlying, configuration and Spoke count.
  const keys = hubs.flatMap((h) => Array.from({ length: h.assetCount }, (_, i) => ({ hub: h.hub, assetId: BigInt(i) })));
  const assetReads = await all(
    client,
    keys.flatMap((k) => [hubCall(k.hub, "getAssetUnderlyingAndDecimals", [k.assetId]), hubCall(k.hub, "getAssetConfig", [k.assetId]), hubCall(k.hub, "getSpokeCount", [k.assetId])]),
  );
  const base = keys.map((k, i) => {
    const [underlying, decimals] = assetReads[i * 3] as [string, number];
    const config = assetReads[i * 3 + 1] as { feeReceiver: string; liquidityFee: number; irStrategy: string };
    return {
      ...k,
      underlying: lower(underlying),
      decimals: Number(decimals),
      feeReceiver: lower(config.feeReceiver),
      liquidityFeeBps: Number(config.liquidityFee),
      irStrategy: lower(config.irStrategy),
      spokeCount: Number(assetReads[i * 3 + 2] as bigint),
    };
  });

  // 3. Spoke addresses and each Spoke's configuration on each asset.
  const addrs = (await all(client, base.flatMap((b) => Array.from({ length: b.spokeCount }, (_, j) => hubCall(b.hub, "getSpokeAddress", [b.assetId, BigInt(j)]))))).map((a) =>
    lower(a as string),
  );
  let cursor = 0;
  const listed = base.map((b) => ({ ...b, spokeAddrs: addrs.slice(cursor, (cursor += b.spokeCount)) }));
  const data = (await all(client, listed.flatMap((b) => b.spokeAddrs.map((sp) => hubCall(b.hub, "getSpoke", [b.assetId, sp]))))) as DecodedSpokeData[];
  cursor = 0;
  const layerOf = (list: ChainDeployment["firstLossReserves"], hub: Address, asset: Address) =>
    list.filter((f) => lower(f.hub) === hub && lower(f.asset) === asset).map((f) => lower(f.address));
  const assets: HubAssetInfo[] = listed.map(({ spokeAddrs, spokeCount: _, ...b }) => ({
    ...b,
    firstLossReserve: layerOf(dep.firstLossReserves, b.hub, b.underlying)[0] ?? ZERO,
    deficitOffsets: layerOf(dep.deficitOffsets, b.hub, b.underlying).filter((o) => spokeAddrs.includes(o)),
    spokes: spokeAddrs.map((spoke) => ({ spoke, data: data[cursor++]! })),
  }));
  const coverage = new Set([...dep.firstLossReserves.map((c) => lower(c.address)), ...dep.deficitOffsets.map((c) => lower(c.address))]);
  const cdp = new Set(cdpSpokes);
  const manifestLend = manifestLendAll.filter((sp) => liveLend.has(sp));

  // 4. Lend Spokes.
  const supplied = new Set(assets.filter((a) => a.spokes.some((s) => manifestLend.includes(s.spoke))).map((a) => a.hub));
  const candidates = uniq(assets.filter((a) => !supplied.has(a.hub)).flatMap((a) => a.spokes.filter((s) => lendShaped(s, a, cdp, coverage)).map((s) => s.spoke)))
    .filter((sp) => !manifestLend.includes(sp))
    .sort();
  const probes = await some(client, candidates.map((sp): ContractCall => ({ address: sp, abi: spokeViewsAbi, functionName: "getReserveCount", args: [] })));
  const lendSpokes = [...manifestLend, ...candidates.filter((_, i) => probes[i] !== null)];

  return { hubs, cdpSpokes, homeHubOf, coverage, lendSpokes, assets };
}

function lendShaped(s: { spoke: Address; data: DecodedSpokeData }, a: { feeReceiver: Address }, cdp: ReadonlySet<Address>, coverage: ReadonlySet<Address>): boolean {
  return !cdp.has(s.spoke) && !coverage.has(s.spoke) && s.spoke !== a.feeReceiver && s.data.active && BigInt(s.data.addCap) > 0n && BigInt(s.data.drawCap) === 0n;
}
