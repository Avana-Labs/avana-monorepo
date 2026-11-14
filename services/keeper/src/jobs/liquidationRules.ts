// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Pure decision and sizing rules of the liquidation job (services/README.md, The liquidatable decision and
// Building the call). No I/O: every input is a value read at the decision block, so each rule is unit-tested.

import type { SkipReason } from "../types.ts";

export const WAD = 10n ** 18n;
export const BPS = 10_000n;

/** Step 2: HF < 1 and collateral above 0. Zero-collateral accounts are skipped: the Spoke already reported their deficit. */
export function candidateReason(healthFactor: bigint, totalCollateralValue: bigint): SkipReason | null {
  if (healthFactor >= WAD) return "healthy";
  if (totalCollateralValue === 0n) return "zeroCollateral";
  return null;
}

export interface MarketGateInput {
  /** PriceView.liquidationState: 0 Live, 1 Drifting, 2 Cached, 3 Expired. */
  readonly liquidationState: number;
  readonly disagreementPauseActive: boolean;
  readonly disagreementExpired: boolean;
  readonly now: bigint;
  /** End of the feed-recovery grace window; 0 when none. */
  readonly graceEndsAt: bigint;
  readonly graceHealthFactor: bigint;
  readonly healthFactor: bigint;
}

/**
 * Step 3, the market gate from `Lens.getPriceState`: Live or Drifting, no disagreement pause, and inside a grace
 * window only accounts below `graceHealthFactor` (0.95). Input age and the sequencer gate are part of the preview
 * (`previewGate`), which re-evaluates every gate as LPVaultSwap does.
 */
export function marketGate(m: MarketGateInput): SkipReason | null {
  if (m.liquidationState !== 0 && m.liquidationState !== 1) return "marketNotLiquidatable";
  if (m.disagreementPauseActive || m.disagreementExpired) return "disagreementPause";
  if (m.now < m.graceEndsAt && m.healthFactor >= m.graceHealthFactor) return "graceAboveThreshold";
  return null;
}

/** The preview fields that decide whether LPVaultSwap would accept the call at this block. */
export interface PreviewGateInput {
  readonly aaveLiquidatable: boolean;
  /** Every input within `liquidationPriceMaxAge`, sequencer up, no disagreement pause. */
  readonly pricesUsable: boolean;
  readonly debtPriceFresh: boolean;
  readonly inGrace: boolean;
  readonly belowGraceHealthFactor: boolean;
  readonly vaultTokenReservePaused: boolean;
  readonly debtReservePaused: boolean;
  readonly debtToCover: bigint;
}

export function previewGate(p: PreviewGateInput): { reason: SkipReason; detail: string } | null {
  if (!p.aaveLiquidatable) return { reason: "healthy", detail: "Aave reports the account not liquidatable" };
  if (!p.pricesUsable) return { reason: "priceTooOld", detail: "collateral price unusable for liquidation" };
  if (!p.debtPriceFresh) return { reason: "priceTooOld", detail: "debt price stale" };
  if (p.inGrace && !p.belowGraceHealthFactor) return { reason: "graceAboveThreshold", detail: "grace window" };
  if (p.vaultTokenReservePaused || p.debtReservePaused) return { reason: "previewGateFalse", detail: "Aave reserve paused" };
  if (p.debtToCover === 0n) return { reason: "previewGateFalse", detail: "preview sized nothing" };
  return null;
}

export interface DebtOption {
  readonly debtReserveId: bigint;
  /** Debt × price, in a common USD unit; only reserves whose price passes are options. */
  readonly value: bigint;
  readonly pricePasses: boolean;
}

/** Step 4: the largest-value debt reserve whose price passes; a failing price on another reserve never blocks it (Q-247). */
export function chooseDebtReserve(options: readonly DebtOption[]): bigint | null {
  let best: DebtOption | null = null;
  for (const o of options) if (o.pricePasses && o.value > 0n && (best === null || o.value > best.value)) best = o;
  return best ? best.debtReserveId : null;
}

/** Deadline: the block's timestamp plus three blocks (36 s on Ethereum, 6 s on Base, REQ-SWAP-074). */
export function deadlineFor(blockTimestamp: bigint, blockTimeSeconds: number): bigint {
  return blockTimestamp + 3n * BigInt(blockTimeSeconds);
}

/** RouteMode 1 (BackupOnly) when the preview reports every primary route unusable, else 0 (PrimaryThenBackup). */
export function routeMode(routes: readonly { routeKind: number; usable: boolean }[]): 0 | 1 {
  const primaries = routes.filter((r) => r.routeKind === 0);
  return primaries.length > 0 && primaries.every((r) => !r.usable) ? 1 : 0;
}

/**
 * Flash amount: the whole `debtToCover` when the lender's idle liquidity covers it with 1 % headroom; otherwise
 * the idle liquidity less 1 %, with the rest from inventory. Never 0: the helper needs a loan of at least one unit.
 */
export function splitFunding(debtToCover: bigint, idle: bigint): { flashAmount: bigint; inventoryAmount: bigint } | null {
  const flashAmount = idle * 100n >= debtToCover * 101n ? debtToCover : (idle * 99n) / 100n;
  if (flashAmount === 0n) return null;
  return { flashAmount, inventoryAmount: debtToCover - flashAmount };
}

/** A contract a swap route calls (`ISettlementRoute.dependencies()`), with what it wraps when it is a wrapper. */
export interface RouteDependency {
  readonly address: `0x${string}`;
  /** `asset()` of an ERC-4626 wrapper and `aToken()` of a static aToken, where the contract answers them. */
  readonly wraps: readonly `0x${string}`[];
}

/**
 * Whether a route into the debt asset draws on the Aave V3 Pool reserve a flash loan of that asset borrows: one of
 * its dependencies is the reserve's aToken or wraps it (an ERC-4626 wrapper of the aToken, a static aToken). The loan
 * would then take the liquidity the route's leg needs, so the call is inventory-funded (services/README.md, Building
 * the call). Without a known aToken nothing can match.
 */
export function routeDrawsOnReserve(deps: readonly RouteDependency[], aToken: `0x${string}` | null): boolean {
  if (aToken === null) return false;
  const a = aToken.toLowerCase();
  return deps.some((d) => d.address.toLowerCase() === a || d.wraps.some((w) => w.toLowerCase() === a));
}

/**
 * How one call is funded. The flash path splits `debtToCover` by `splitFunding`. The inventory-only path (`F = 0`, which
 * only the operator helper accepts, REQ-HELPER-003) funds the whole repayment from the funding Safe: when flash
 * funding is stopped (the Aave V3 Pool's implementation is not the manifest's), or when the loan would round to zero
 * (no idle liquidity, or a dust repayment the 1 % headroom floors to nothing).
 */
export function fundingPlan(debtToCover: bigint, idle: bigint, flashUsable: boolean): { flashAmount: bigint; inventoryAmount: bigint; inventoryOnly: boolean } {
  const split = flashUsable ? splitFunding(debtToCover, idle) : null;
  if (!split) return { flashAmount: 0n, inventoryAmount: debtToCover, inventoryOnly: true };
  return { ...split, inventoryOnly: false };
}

/**
 * Top-up bound: 0 for a profitable call, otherwise premium + expectedCallerLoss − expectedNetPayout from the
 * preview (REQ-LENS-029), capped so the Safe's whole outflow stays within MAX_TOP_UP_BPS of the debt repaid (FL-02).
 */
export function topUpBound(p: { premium: bigint; expectedCallerLoss: bigint; expectedNetPayout: bigint; expectedDebtRepaid: bigint; maxTopUpBps: bigint }): bigint {
  const need = p.premium + p.expectedCallerLoss - p.expectedNetPayout;
  if (need <= 0n) return 0n;
  const cap = (p.expectedDebtRepaid * p.maxTopUpBps) / BPS;
  return need < cap ? need : cap;
}

/**
 * The request's `minPayout`, on the net payout (Q-345). `net` is the simulated net result of the call at the
 * block: keeperOut − debtToCover − premium. A profitable call keeps 99 % of it; a losing call accepts at most
 * 101 % of the simulated loss.
 */
export function requestMinPayout(inventoryAmount: bigint, net: bigint): bigint {
  if (net >= 0n) return inventoryAmount + (net * 99n) / 100n;
  const allowedLoss = (-net * 101n + 99n) / 100n;
  return inventoryAmount > allowedLoss ? inventoryAmount - allowedLoss : 0n;
}
