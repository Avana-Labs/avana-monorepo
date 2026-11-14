// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The failure-reason table (services/README.md, Submission > Failure reasons): what the keeper does after a
// liquidation's simulation reverts with each reason, and how a retry's request is widened for the two reasons that a
// larger bound can cure. Pure rules plus revert decoding; the liquidation job applies them.

import { type Abi, type Hex, decodeErrorResult, slice } from "viem";
import { aaveV4SpokeAbi, debtOracleAbi, flashLiquidatorAbi, lpOracleAbi, lpVaultSwapAbi } from "@avana/protocol/abis";
import { BPS } from "./liquidationRules.ts";

/** Errors a liquidation can revert with: LPVaultSwap and the helper first, then the oracles and the Spoke it reaches. */
export const LIQUIDATION_ERROR_ABI: Abi = [...lpVaultSwapAbi, ...flashLiquidatorAbi, ...lpOracleAbi, ...debtOracleAbi, ...aaveV4SpokeAbi] as Abi;

export interface Revert {
  readonly selector: Hex;
  /** Decoded error name, or "unknown" for an error outside the ABIs above. */
  readonly name: string;
  /** Decoded arguments as decimal or hex strings, so the attempt log stays plain JSON. */
  readonly args?: readonly string[];
}

/** Revert data of a failed call: viem nests it under `cause` one or more levels deep. */
export function revertData(err: unknown): Hex | undefined {
  for (let e = err as { data?: unknown; cause?: unknown } | undefined, depth = 0; e && depth < 8; e = e.cause as typeof e, depth++) {
    if (typeof e.data === "string" && e.data.startsWith("0x")) return e.data as Hex;
    if (e.data && typeof e.data === "object" && typeof (e.data as { data?: unknown }).data === "string") return (e.data as { data: Hex }).data;
  }
  return undefined;
}

export function decodeRevert(data: Hex | undefined, abi: Abi = LIQUIDATION_ERROR_ABI): Revert | undefined {
  if (!data || data.length < 10) return undefined;
  const selector = slice(data, 0, 4);
  try {
    const r = decodeErrorResult({ abi, data });
    return { selector, name: r.errorName, args: (r.args ?? []).map((a) => (typeof a === "bigint" ? a.toString(10) : String(a))) };
  } catch {
    return { selector, name: "unknown" };
  }
}

/** A simulation inside a job's build reverted; the pipeline routes it to the job's failure handler. */
export class RevertError extends Error {
  constructor(
    readonly revert: Revert,
    /** The plan subject (`chainId:spoke:proxy` for a liquidation), when the build knew it. */
    readonly subject?: string,
  ) {
    super(`simulation reverted: ${revert.name}`);
  }
}

export type FailureAction =
  /** `NotLiquidatable`: another caller won or the account recovered; the episode is cleared and the next read decides. */
  | { readonly kind: "clearAccount" }
  /** `StalePrice`, `DebtPriceStale`: wait for a fresh price; the market gate re-checks every block. */
  | { readonly kind: "waitForPrice" }
  /** `PayoutTooLow`, `MinOutNotMet`, `LockHeld`: a new preview in the next block. */
  | { readonly kind: "retryNextBlock" }
  /** `RecoveryBelowFloor`: retry with `maxShortfall` covering the floor gap from inventory; M-10. */
  | { readonly kind: "retryWithShortfall"; readonly signal: "M-10"; readonly level: "warn" }
  /** `TopUpExceeded`: retry with a top-up bound covering the measured loss. */
  | { readonly kind: "retryWithTopUp" }
  /** `InsufficientProceeds` never fires while the caller funds the debt: a fault, paged. */
  | { readonly kind: "fault"; readonly signal: "M-10"; readonly level: "page" }
  /** `NoRouteAvailable`: retry every block and page (playbook P-04). */
  | { readonly kind: "retryAndPage"; readonly signal: "M-10"; readonly level: "page" }
  /** `AddressIsFrozen`: the guardian froze the helper; stop submitting from it and page (M-24). */
  | { readonly kind: "stopHelper"; readonly signal: "M-24"; readonly level: "page" }
  /** Any other reason: logged with its selector; the next block decides afresh. */
  | { readonly kind: "unknown" };

export function failureAction(name: string): FailureAction {
  switch (name) {
    case "NotLiquidatable":
      return { kind: "clearAccount" };
    case "StalePrice":
    case "DebtPriceStale":
      return { kind: "waitForPrice" };
    case "PayoutTooLow":
    case "MinOutNotMet":
    case "LockHeld":
      return { kind: "retryNextBlock" };
    case "RecoveryBelowFloor":
      return { kind: "retryWithShortfall", signal: "M-10", level: "warn" };
    case "TopUpExceeded":
      return { kind: "retryWithTopUp" };
    case "InsufficientProceeds":
      return { kind: "fault", signal: "M-10", level: "page" };
    case "NoRouteAvailable":
      return { kind: "retryAndPage", signal: "M-10", level: "page" };
    case "AddressIsFrozen":
      return { kind: "stopHelper", signal: "M-24", level: "page" };
    default:
      return { kind: "unknown" };
  }
}

/** What a failed attempt leaves for the next build of the same account. */
export interface RetryHint {
  /** Set after `RecoveryBelowFloor`: the next request carries a shortfall allowance. */
  readonly shortfall?: true;
  /** Set after `TopUpExceeded(topUp, bound)`: the top-up the call needed. */
  readonly topUp?: bigint;
}

export function hintFor(revert: Revert): RetryHint | null {
  const action = failureAction(revert.name);
  if (action.kind === "retryWithShortfall") return { shortfall: true };
  if (action.kind === "retryWithTopUp" && revert.args?.[0] !== undefined) return { topUp: BigInt(revert.args[0]) };
  return null;
}

/**
 * The most the funding Safe may put into one call beyond the inventory amount: `MAX_TOP_UP_BPS` of the debt repaid,
 * the operator helper's own bound (FL-02). Both the shortfall allowance and the top-up bound stay within it.
 */
export function topUpCap(expectedDebtRepaid: bigint, maxTopUpBps: bigint): bigint {
  return (expectedDebtRepaid * maxTopUpBps) / BPS;
}

/**
 * Widens a request after a revert a larger bound can cure, or returns null when it cannot:
 * - `RecoveryBelowFloor` (no arguments, so the gap is not measured on-chain): `maxShortfall` and the top-up bound
 *   both go to the cap. They are ceilings only; the request's `minPayout`, taken from the simulation of the widened
 *   call, still holds the actual loss to 101 % of the simulated one.
 * - `TopUpExceeded(topUp, bound)`: the top-up bound goes to the measured `topUp`, if the cap allows it.
 */
export function widen(
  current: { readonly maxShortfall: bigint; readonly maxTopUp: bigint },
  hint: RetryHint,
  cap: bigint,
): { maxShortfall: bigint; maxTopUp: bigint } | null {
  if (hint.shortfall) {
    if (current.maxShortfall >= cap || cap === 0n) return null;
    return { maxShortfall: cap, maxTopUp: current.maxTopUp > cap ? current.maxTopUp : cap };
  }
  if (hint.topUp !== undefined) {
    if (hint.topUp <= current.maxTopUp || hint.topUp > cap) return null;
    return { maxShortfall: current.maxShortfall, maxTopUp: hint.topUp };
  }
  return null;
}
