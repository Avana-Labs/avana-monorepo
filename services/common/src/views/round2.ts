// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Lens views planned for the second Lens round, with the shapes the services read from them. Until a Lens with
// these views is deployed and its ABI generated in packages/protocol, nothing calls the readers below: the
// snapshot reads the same numbers from round-1 Lens views and the Hub and Spoke directly (snapshot.ts). When the
// views land, each reader's fragment is replaced by the generated ABI and the snapshot switches to it; the row
// types in types.ts do not change.

import { parseAbi } from "viem";
import type { DecimalString } from "../export.ts";
import type { ContractCall, ViewClient } from "./snapshot.ts";
import type { Address, HubAssetRow, HubAssetSpokeRow } from "./types.ts";

/** Planned `getHubAsset(hub, assetId)`: the Hub part of `DebtReserveView` for any Hub asset, with its slices. */
export interface HubAssetViewPlanned {
  readonly blockNumber: bigint;
  readonly timestamp: bigint;
  readonly hub: Address;
  readonly assetId: bigint;
  readonly underlying: Address;
  readonly decimals: number;
  readonly added: bigint;
  readonly addedShares: bigint;
  readonly drawn: bigint;
  readonly premium: bigint;
  readonly liquidity: bigint;
  readonly deficit: bigint;
  readonly accruedFees: bigint;
  readonly drawnIndexRay: bigint;
  readonly drawnRateRay: bigint;
  readonly supplyRateRay: bigint;
  readonly utilizationBps: bigint;
  readonly liquidityFeeBps: bigint;
  readonly optimalUsageBps: bigint;
  readonly baseDrawnRateBps: bigint;
  readonly rateGrowthBeforeOptimalBps: bigint;
  readonly rateGrowthAfterOptimalBps: bigint;
  readonly spokes: readonly SpokeDrawPlanned[];
}

/** Planned extension of `SpokeDraw`: added, caps, shares and flags of each slice (today: drawCap, drawn, deficit). */
export interface SpokeDrawPlanned {
  readonly spoke: Address;
  readonly homeHub: Address;
  readonly drawCap: bigint;
  readonly drawn: bigint;
  readonly deficit: bigint;
  readonly added: bigint;
  readonly addedShares: bigint;
  readonly addCap: bigint;
  readonly drawnShares: bigint;
  readonly premiumShares: bigint;
  readonly active: boolean;
  readonly halted: boolean;
}

/** Planned `MarketView` additions: the market's own borrow rate per debt reserve and its liquidation config. */
export interface MarketViewAdditionsPlanned {
  readonly collateralRiskBps: bigint;
  readonly targetHealthFactor: bigint;
  readonly healthFactorForMaxBonus: bigint;
  readonly liquidationBonusFactorBps: bigint;
  readonly liquidationFeeBps: bigint;
  readonly borrowRatesRay: readonly { readonly reserveId: bigint; readonly rateRay: bigint }[];
}

/** Planned uncollected-fees view of one record: AMM fees owed to the position, in pool token order. */
export interface UncollectedFeesPlanned {
  readonly blockNumber: bigint;
  readonly positionKey: `0x${string}`;
  readonly tokens: readonly Address[];
  readonly amounts: readonly bigint[];
  readonly valueUsd8: bigint;
}

/** Planned after-action previews (supply/pledge, borrow, repay, withdraw), one shape for the action page. */
export interface ActionPreviewPlanned {
  readonly blockNumber: bigint;
  readonly healthFactorBefore: bigint;
  readonly healthFactorAfter: bigint;
  readonly collateralValueAfter: bigint;
  readonly debtValueAfterRay: bigint;
  readonly borrowRateAfterRay: bigint;
  readonly allowed: boolean;
}

/** Planned inverse sizing: the largest amount of an action that keeps the health factor at or above a target. */
export interface InverseSizingPlanned {
  readonly blockNumber: bigint;
  readonly amount: bigint;
  readonly healthFactorAfter: bigint;
}

/** The planned fragment of `getHubAsset`; the field order must match the Solidity struct once it exists. */
export const plannedHubAssetAbi = parseAbi([
  "struct SpokeDrawPlanned { address spoke; address homeHub; uint256 drawCap; uint256 drawn; uint256 deficit; uint256 added; uint256 addedShares; uint256 addCap; uint256 drawnShares; uint256 premiumShares; bool active; bool halted; }",
  "struct HubAssetViewPlanned { uint256 blockNumber; uint256 timestamp; address hub; uint256 assetId; address underlying; uint8 decimals; uint256 added; uint256 addedShares; uint256 drawn; uint256 premium; uint256 liquidity; uint256 deficit; uint256 accruedFees; uint256 drawnIndexRay; uint256 drawnRateRay; uint256 supplyRateRay; uint256 utilizationBps; uint256 liquidityFeeBps; uint256 optimalUsageBps; uint256 baseDrawnRateBps; uint256 rateGrowthBeforeOptimalBps; uint256 rateGrowthAfterOptimalBps; SpokeDrawPlanned[] spokes; }",
  "function getHubAsset(address hub, uint256 assetId) view returns (HubAssetViewPlanned view_)",
]);

/** Thrown by every round-2 reader while `ROUND2_ENABLED` is false. */
export class LensRound2Unavailable extends Error {
  constructor(view: string) {
    super(`Lens view ${view} is not deployed yet; read it through snapshot.ts`);
  }
}

/** Flipped when the round-2 Lens is in the release manifest and its ABI is generated. */
export const ROUND2_ENABLED = false;

/** Reads `getHubAsset` (planned). */
export async function readHubAssetRound2(client: ViewClient, lens: Address, hub: Address, assetId: bigint): Promise<HubAssetViewPlanned> {
  if (!ROUND2_ENABLED) throw new LensRound2Unavailable("getHubAsset");
  const call: ContractCall = { address: lens, abi: plannedHubAssetAbi, functionName: "getHubAsset", args: [hub, assetId] };
  const [r] = await client.multicall([call]);
  if (!r || r.status !== "success") throw new Error(`getHubAsset(${hub}, ${assetId}) reverted`);
  return r.result as HubAssetViewPlanned;
}

/** Reads uncollected fees of one position (planned). */
export async function readUncollectedFeesRound2(_client: ViewClient, _lens: Address, _marketId: bigint, _positionKey: `0x${string}`): Promise<UncollectedFeesPlanned> {
  throw new LensRound2Unavailable("getUncollectedFees");
}

/** Reads an after-action preview (planned). */
export async function readActionPreviewRound2(
  _client: ViewClient,
  _lens: Address,
  _action: "pledge" | "borrow" | "repay" | "withdraw",
  _wallet: Address,
  _marketId: bigint,
  _amount: bigint,
): Promise<ActionPreviewPlanned> {
  throw new LensRound2Unavailable("preview after action");
}

/** Reads inverse sizing (planned). */
export async function readInverseSizingRound2(
  _client: ViewClient,
  _lens: Address,
  _action: "borrow" | "withdraw",
  _wallet: Address,
  _marketId: bigint,
  _targetHealthFactorWad: bigint,
): Promise<InverseSizingPlanned> {
  throw new LensRound2Unavailable("inverse sizing");
}

const s = (x: bigint): DecimalString => x.toString(10);

/** Maps the planned view onto the existing rows, so switching the snapshot to it changes no consumer. */
export function hubAssetRowsFromRound2(
  chainId: number,
  v: HubAssetViewPlanned,
  extra: Pick<HubAssetRow, "priceUsd8" | "feeReceiver" | "lend" | "lendReserves" | "exposure">,
  kindOf: (spoke: Address, homeHub: Address) => HubAssetSpokeRow["kind"],
): { asset: HubAssetRow; slices: HubAssetSpokeRow[] } {
  const block = s(v.blockNumber);
  const asset: HubAssetRow = {
    chainId,
    hub: v.hub.toLowerCase() as Address,
    assetId: s(v.assetId),
    underlying: v.underlying.toLowerCase() as Address,
    decimals: v.decimals,
    added: s(v.added),
    addedShares: s(v.addedShares),
    drawn: s(v.drawn),
    premium: s(v.premium),
    owed: s(v.drawn + v.premium),
    liquidity: s(v.liquidity),
    deficit: s(v.deficit),
    accruedFees: s(v.accruedFees),
    drawnIndexRay: s(v.drawnIndexRay),
    drawnRateRay: s(v.drawnRateRay),
    supplyRateRay: s(v.supplyRateRay),
    utilizationBps: Number(v.utilizationBps),
    liquidityFeeBps: Number(v.liquidityFeeBps),
    rateCurve: {
      optimalUsageBps: Number(v.optimalUsageBps),
      baseDrawnRateBps: Number(v.baseDrawnRateBps),
      rateGrowthBeforeOptimalBps: Number(v.rateGrowthBeforeOptimalBps),
      rateGrowthAfterOptimalBps: Number(v.rateGrowthAfterOptimalBps),
    },
    blockNumber: block,
    timestamp: Number(v.timestamp),
    ...extra,
  };
  const slices = v.spokes.map((d) => ({
    chainId,
    hub: asset.hub,
    assetId: asset.assetId,
    spoke: d.spoke.toLowerCase() as Address,
    kind: kindOf(d.spoke.toLowerCase() as Address, d.homeHub.toLowerCase() as Address),
    homeHub: d.homeHub.toLowerCase() as Address,
    added: s(d.added),
    addedShares: s(d.addedShares),
    owed: s(d.drawn),
    drawnShares: s(d.drawnShares),
    premiumShares: s(d.premiumShares),
    deficit: s(d.deficit),
    addCap: s(d.addCap),
    drawCap: s(d.drawCap),
    active: d.active,
    halted: d.halted,
    blockNumber: block,
  }));
  return { asset, slices };
}
