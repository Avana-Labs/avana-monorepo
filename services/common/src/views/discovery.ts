// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Finds what one chain's snapshot reads, at the snapshot's block: every Hub (the manifest's and every one the
// MarketRegistry has recorded since), every CDP Spoke (the manifest's and every one the registry has approved since),
// each Hub asset with its Spokes, and the Lend Spokes. A Hub, Spoke or asset listed on chain after the services
// started is therefore read at the next sample with no change to the deployment the services were given.
//
// Lend Spokes are not recorded by the MarketRegistry (they are Aave standard Spokes). The manifest's Lend Spokes are
// always read; on a Hub that none of them supplies (a Hub recorded after the manifest), a Spoke is read as a Lend
// Spoke when it is shaped like one: not a CDP Spoke, not a Coverage Spoke, not the asset's fee receiver, active, with
// an add cap and no draw cap, and answering `getReserveCount`.

import { hubViewsAbi, lensViewsAbi, registryViewsAbi, spokeViewsAbi } from "./abi.ts";
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
  readonly label: string | null;
  readonly tier: number;
  readonly recorded: boolean;
  readonly applicationState: number | null;
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
  /** `MarketRegistry.coverageSpokeOf(hub, underlying)`; the zero address when none is set. */
  readonly coverageSpoke: Address;
  readonly spokes: readonly { readonly spoke: Address; readonly data: DecodedSpokeData }[];
}

export interface Topology {
  readonly hubs: readonly HubInfo[];
  readonly cdpSpokes: readonly Address[];
  /** `MarketRegistry.hubOf(spoke)` of every CDP Spoke. */
  readonly homeHubOf: ReadonlyMap<Address, Address>;
  readonly coverage: ReadonlySet<Address>;
  /** The manifest's Lend Spokes in manifest order, then those found on later Hubs in address order. */
  readonly lendSpokes: readonly Address[];
  readonly assets: readonly HubAssetInfo[];
  readonly crossHubLinesEnabled: boolean;
}

const reg = (registry: Address, functionName: string, args: readonly unknown[] = []): ContractCall => ({ address: registry, abi: registryViewsAbi, functionName, args });
const hubCall = (hub: Address, functionName: string, args: readonly unknown[] = []): ContractCall => ({ address: hub, abi: hubViewsAbi, functionName, args });

/** Reads the Hubs, Spokes and Hub assets the snapshot covers. */
export async function discover(client: ViewClient, dep: ChainDeployment): Promise<Topology> {
  const registry = lower(dep.marketRegistry);
  const lens = lower(dep.lens);

  // 1. The registry's Hubs and CDP Spokes, and whether Hub-to-Hub lines are open.
  const [recordedHubs, approvedSpokes, crossHubLinesEnabled] = (await all(client, [reg(registry, "getHubs"), reg(registry, "getSpokes"), reg(registry, "crossHubLinesEnabled")])) as [
    readonly string[],
    readonly string[],
    boolean,
  ];
  const labels = new Map(dep.hubs.map((h) => [lower(h.address), h.label]));
  const hubAddrs = uniq([...dep.hubs.map((h) => lower(h.address)), ...recordedHubs.map(lower)]);
  const cdpSpokes = uniq([...dep.cdpSpokes.map(lower), ...approvedSpokes.map(lower)]);

  // 2. Each Hub's asset count and registry record, each CDP Spoke's home Hub; the tier and application state may
  // revert for a Hub the registry has not recorded.
  const n = hubAddrs.length;
  const required = await all(client, [
    ...hubAddrs.map((h) => hubCall(h, "getAssetCount")),
    ...hubAddrs.map((h) => reg(registry, "isRecordedHub", [h])),
    ...cdpSpokes.map((sp) => reg(registry, "hubOf", [sp])),
  ]);
  const optional = await some(client, [
    ...hubAddrs.map((h) => reg(registry, "hubTier", [h])),
    ...hubAddrs.map((h): ContractCall => ({ address: lens, abi: lensViewsAbi, functionName: "getApplicationState", args: [h] })),
  ]);
  const hubs: HubInfo[] = hubAddrs.map((hub, i) => ({
    hub,
    label: labels.get(hub) ?? null,
    assetCount: Number(required[i] as bigint),
    recorded: required[n + i] as boolean,
    tier: optional[i] === null ? 0 : Number(optional[i]),
    applicationState: optional[n + i] === null ? null : Number(optional[n + i]),
  }));
  const homeHubOf = new Map(cdpSpokes.map((sp, i) => [sp, lower(required[2 * n + i] as string)]));

  // 3. Each Hub asset's underlying, configuration and Spoke count.
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

  // 4. Spoke addresses and the registry's Coverage Spoke of each asset.
  const addrs = (await all(client, base.flatMap((b) => Array.from({ length: b.spokeCount }, (_, j) => hubCall(b.hub, "getSpokeAddress", [b.assetId, BigInt(j)]))))).map((a) =>
    lower(a as string),
  );
  const covers = await some(client, base.map((b) => reg(registry, "coverageSpokeOf", [b.hub, b.underlying])));
  let cursor = 0;
  const listed = base.map((b) => ({ ...b, spokeAddrs: addrs.slice(cursor, (cursor += b.spokeCount)) }));

  // 5. Each Spoke's configuration on each asset.
  const data = (await all(client, listed.flatMap((b) => b.spokeAddrs.map((sp) => hubCall(b.hub, "getSpoke", [b.assetId, sp]))))) as DecodedSpokeData[];
  cursor = 0;
  const assets: HubAssetInfo[] = listed.map(({ spokeAddrs, spokeCount: _, ...b }, i) => ({
    ...b,
    coverageSpoke: covers[i] ? lower(covers[i] as string) : ZERO,
    spokes: spokeAddrs.map((spoke) => ({ spoke, data: data[cursor++]! })),
  }));

  // 6. Lend Spokes.
  const coverage = new Set([...dep.coverageSpokes.map((c) => lower(c.address)), ...assets.map((a) => a.coverageSpoke).filter((a) => a !== ZERO)]);
  const cdp = new Set(cdpSpokes);
  const manifestLend = uniq(dep.lendSpokes.map(lower));
  const supplied = new Set(assets.filter((a) => a.spokes.some((s) => manifestLend.includes(s.spoke))).map((a) => a.hub));
  const candidates = uniq(
    assets.filter((a) => !supplied.has(a.hub)).flatMap((a) => a.spokes.filter((s) => lendShaped(s, a, cdp, coverage)).map((s) => s.spoke)),
  )
    .filter((sp) => !manifestLend.includes(sp))
    .sort();
  const probes = await some(client, candidates.map((sp): ContractCall => ({ address: sp, abi: spokeViewsAbi, functionName: "getReserveCount", args: [] })));
  const lendSpokes = [...manifestLend, ...candidates.filter((_, i) => probes[i] !== null)];

  return { hubs, cdpSpokes, homeHubOf, coverage, lendSpokes, assets, crossHubLinesEnabled };
}

function lendShaped(s: { spoke: Address; data: DecodedSpokeData }, a: { feeReceiver: Address }, cdp: ReadonlySet<Address>, coverage: ReadonlySet<Address>): boolean {
  return !cdp.has(s.spoke) && !coverage.has(s.spoke) && s.spoke !== a.feeReceiver && s.data.active && BigInt(s.data.addCap) > 0n && BigInt(s.data.drawCap) === 0n;
}
