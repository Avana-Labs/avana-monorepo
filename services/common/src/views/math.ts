// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Exact integer math on snapshot rows (Hub accounting identities, cap room, borrowable headroom) and the one
// conversion each page uses for USD and percentages. Integer results round the way the Hub and the Lens round,
// so a figure shown never overstates what a lender can withdraw or a borrower can draw.

import type { DecimalString } from "../export.ts";
import type { HubAssetRow, HubAssetSpokeRow } from "./types.ts";

export const RAY = 10n ** 27n;
export const WAD = 10n ** 18n;
/** Aave V4 `MAX_ALLOWED_SPOKE_CAP` (uint40 max): a cap at this value is unlimited. */
export const MAX_SPOKE_CAP = 2n ** 40n - 1n;

const big = (x: DecimalString | bigint | number): bigint => (typeof x === "bigint" ? x : BigInt(x));
const min = (a: bigint, b: bigint): bigint => (a < b ? a : b);

export function ceilDiv(a: bigint, b: bigint): bigint {
  if (b <= 0n) throw new Error("division by a non-positive number");
  return a === 0n ? 0n : (a - 1n) / b + 1n;
}

/** ⌊owed × 10⁴ / added⌋, 0 when nothing is added. */
export function utilizationBps(owed: bigint, added: bigint): number {
  return added === 0n ? 0 : Number((owed * 10_000n) / added);
}

/** Supply rate, RAY: ⌊drawnRate × owed × (10⁴ − liquidityFee) / (added × 10⁴)⌋ (REQ-LENS-046). */
export function supplyRateRay(drawnRateRay: bigint, owed: bigint, added: bigint, liquidityFeeBps: number): bigint {
  if (added === 0n) return 0n;
  return (drawnRateRay * owed * (10_000n - BigInt(liquidityFeeBps))) / (added * 10_000n);
}

/** Deficit in base units, rounded up as the Hub's aggregate does. */
export function deficitFromRay(deficitRay: bigint): bigint {
  return ceilDiv(deficitRay, RAY);
}

/**
 * A Spoke's room under its draw cap in base units: `max(0, drawCap × 10^dec − owed − deficit)`, or null when the cap
 * is unlimited. A reported deficit still uses cap until it is eliminated.
 */
export function capRoom(slice: Pick<HubAssetSpokeRow, "drawCap" | "owed" | "deficit">, decimals: number): bigint | null {
  const cap = big(slice.drawCap);
  if (cap === MAX_SPOKE_CAP) return null;
  const room = cap * 10n ** BigInt(decimals) - big(slice.owed) - big(slice.deficit);
  return room > 0n ? room : 0n;
}

/** What one Spoke can draw now: `min(capRoom, liquidity)`. */
export function spokeHeadroom(slice: HubAssetSpokeRow, asset: Pick<HubAssetRow, "liquidity" | "decimals">): bigint {
  const room = capRoom(slice, asset.decimals);
  const liquidity = big(asset.liquidity);
  return room === null ? liquidity : min(room, liquidity);
}

/**
 * What every CDP Spoke together can draw: `min(Σ capRoom, liquidity)`. The Spokes share one liquidity, so this is
 * less than the sum of their headrooms whenever liquidity binds.
 */
export function assetBorrowable(asset: Pick<HubAssetRow, "liquidity" | "decimals">, slices: readonly HubAssetSpokeRow[]): bigint {
  const liquidity = big(asset.liquidity);
  let rooms = 0n;
  for (const s of slices) {
    if (s.kind !== "cdp") continue;
    const room = capRoom(s, asset.decimals);
    if (room === null) return liquidity;
    rooms += room;
  }
  return min(rooms, liquidity);
}

/** How the Spoke slices of one Hub asset add up to the Hub's totals at the same block. */
export interface Reconciliation {
  readonly hubOwed: bigint;
  readonly cdpOwed: bigint;
  /** Σ CDP slice owed − Hub owed; each Spoke rounds up, so 0 ≤ gap ≤ number of drawing Spokes. */
  readonly owedGap: bigint;
  readonly owedReconciles: boolean;
  readonly hubAdded: bigint;
  readonly slicesAdded: bigint;
  /** Hub added − Σ slice added; each Spoke rounds down, so 0 ≤ gap ≤ number of Spokes. */
  readonly addedGap: bigint;
  readonly addedReconciles: boolean;
  /** Only CDP Spokes draw: a draw by any other Spoke breaks REQ-HUB-015. */
  readonly onlyCdpDraws: boolean;
  /** added + accruedFees − (liquidity + owed + deficit); the Hub rounds owed and deficit up once, so |gap| ≤ 2. */
  readonly balanceGap: bigint;
  readonly balanceHolds: boolean;
  readonly addedByKind: Readonly<Record<HubAssetSpokeRow["kind"], bigint>>;
}

export function reconcileHubAsset(asset: HubAssetRow, slices: readonly HubAssetSpokeRow[]): Reconciliation {
  const mine = slices.filter((s) => s.chainId === asset.chainId && s.hub === asset.hub && s.assetId === asset.assetId);
  const mixed = mine.filter((s) => s.blockNumber !== asset.blockNumber);
  if (mixed.length > 0) throw new Error(`slices of ${asset.hub}:${asset.assetId} read at another block than the asset`);
  const addedByKind = { lend: 0n, cdp: 0n, coverage: 0n, feeReceiver: 0n, other: 0n, deficitOffset: 0n };
  let cdpOwed = 0n;
  let slicesAdded = 0n;
  let drawingSpokes = 0n;
  let onlyCdpDraws = true;
  for (const s of mine) {
    const owed = big(s.owed);
    addedByKind[s.kind] += big(s.added);
    slicesAdded += big(s.added);
    if (owed > 0n) {
      drawingSpokes += 1n;
      if (s.kind !== "cdp") onlyCdpDraws = false;
    }
    if (s.kind === "cdp") cdpOwed += owed;
  }
  const hubOwed = big(asset.owed);
  const hubAdded = big(asset.added);
  const owedGap = cdpOwed - hubOwed;
  const addedGap = hubAdded - slicesAdded;
  const balanceGap = hubAdded + big(asset.accruedFees) - (big(asset.liquidity) + hubOwed + big(asset.deficit));
  return {
    hubOwed,
    cdpOwed,
    owedGap,
    owedReconciles: owedGap >= 0n && owedGap <= drawingSpokes,
    hubAdded,
    slicesAdded,
    addedGap,
    addedReconciles: addedGap >= 0n && addedGap <= BigInt(mine.length),
    onlyCdpDraws,
    balanceGap,
    balanceHolds: balanceGap >= -2n && balanceGap <= 2n,
    addedByKind,
  };
}

/** USD value of base units at an 8-decimal price, as a float for display; the product is exact before the division. */
export function usd(units: DecimalString | bigint, decimals: number, priceUsd8: DecimalString | bigint): number {
  const usd8 = (big(units) * big(priceUsd8)) / 10n ** BigInt(decimals);
  return Number(usd8) / 1e8;
}

/** Whole-token amount of base units, as a float for display. */
export function tokens(units: DecimalString | bigint, decimals: number): number {
  const scale = 10n ** BigInt(decimals);
  const u = big(units);
  return Number(u / scale) + Number(u % scale) / Number(scale);
}

/** Linear annual rate (RAY) as a percent. */
export function rayToAprPct(rateRay: DecimalString | bigint): number {
  return (Number((big(rateRay) * 10n ** 12n) / RAY) / 1e12) * 100;
}

/** Linear annual rate (RAY) as the APY of continuous compounding, percent: (e^r − 1) × 100. */
export function rayToApyPct(rateRay: DecimalString | bigint): number {
  return Math.expm1(rayToAprPct(rateRay) / 100) * 100;
}

export function bpsToPct(bps: number | bigint): number {
  return Number(bps) / 100;
}

/** A borrower's rate on a market: `drawnRate × (1 + collateralRisk)`, rounded up as the Lens rounds it. */
export function marketBorrowRateRay(drawnRateRay: DecimalString | bigint, collateralRiskBps: number): bigint {
  return ceilDiv(big(drawnRateRay) * (10_000n + BigInt(collateralRiskBps)), 10_000n);
}
