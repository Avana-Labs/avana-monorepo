// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Transaction progress (README, "Transaction progress"): after the wallet submits, the app records an intent with
// the transaction hash only (never a target, amount or calldata: REQ-ARCH-140). A tracker reads the receipt at the
// head over Convex's own RPC and moves the intent:
//
//   pending ─receipt ok─▶ included ─export delivers the tx─▶ indexed (final)
//      │ └─receipt reverted─▶ failed
//      └─no receipt for DROP_AFTER_MS─▶ dropped (final)
//   included / failed ─its block no longer canonical (reorg)─▶ pending
//   included ─block finalized, export still without the tx after EXPORT_GRACE_MS─▶ confirmed (final)
//   failed ─block finalized─▶ failed (final)
//
// `confirmed` covers transactions the export never carries (a token approval, a swap outside the protocol).
// `indexed` comes from the export, which serves finalized blocks only, so an indexed intent cannot be reorged.

export type IntentStatus = "pending" | "included" | "failed" | "indexed" | "confirmed" | "dropped";

/** A pending intent with no receipt this long after submission is dropped (replaced, or never broadcast). */
export const DROP_AFTER_MS = 60 * 60 * 1000;

/** How long after its block is finalized the tracker waits for the export before calling an intent confirmed. */
export const EXPORT_GRACE_MS = 10 * 60 * 1000;

export interface IntentState {
  readonly status: IntentStatus;
  readonly submittedAt: number;
  readonly blockNumber?: string;
  readonly blockHash?: string;
  /** When the tracker first saw the intent's block at or below the finalized block. */
  readonly finalizedAt?: number;
}

export interface Observation {
  /** The receipt over Convex's RPC, or null when the node has none. */
  readonly receipt: { readonly success: boolean; readonly blockNumber: string; readonly blockHash: string } | null;
  /** The canonical hash at the intent's stored block now; null when it has no block or the read failed. */
  readonly canonicalHash: string | null;
  /** Whether an imported (finalized) log carries the transaction hash. */
  readonly indexed: boolean;
  /** The chain's finalized block number now. */
  readonly finalizedBlock: string | null;
  readonly now: number;
}

export const isFinal = (s: IntentStatus, finalizedAt?: number) => s === "indexed" || s === "confirmed" || s === "dropped" || (s === "failed" && finalizedAt !== undefined);

/** The next state of an intent after one observation; returns the same object when nothing changed. */
export function nextIntentState(i: IntentState, o: Observation): IntentState {
  if (isFinal(i.status, i.finalizedAt)) return i;
  // Only a successful transaction emits logs, so a finalized log with the hash settles the intent whatever the
  // node's receipt says now.
  if (o.indexed) {
    const at = o.receipt ?? (i.blockNumber && i.blockHash ? { blockNumber: i.blockNumber, blockHash: i.blockHash } : null);
    return { status: "indexed", submittedAt: i.submittedAt, ...(at ? { blockNumber: at.blockNumber, blockHash: at.blockHash } : {}) };
  }
  if (i.status === "included" || i.status === "failed") {
    // A reorg removed the block: the transaction may be re-included elsewhere or dropped, so it waits again.
    if (i.blockHash && o.canonicalHash !== null && o.canonicalHash !== i.blockHash) return { status: "pending", submittedAt: i.submittedAt };
    if (o.receipt && o.receipt.blockHash !== i.blockHash) return { status: o.receipt.success ? "included" : "failed", submittedAt: i.submittedAt, blockNumber: o.receipt.blockNumber, blockHash: o.receipt.blockHash };
    const finalized = i.blockNumber !== undefined && o.finalizedBlock !== null && BigInt(i.blockNumber) <= BigInt(o.finalizedBlock);
    if (!finalized) return i;
    if (i.finalizedAt === undefined) return { ...i, finalizedAt: o.now };
    if (i.status === "included" && o.now - i.finalizedAt > EXPORT_GRACE_MS) return { ...i, status: "confirmed" };
    return i;
  }
  if (o.receipt) return { status: o.receipt.success ? "included" : "failed", submittedAt: i.submittedAt, blockNumber: o.receipt.blockNumber, blockHash: o.receipt.blockHash };
  if (o.now - i.submittedAt > DROP_AFTER_MS) return { status: "dropped", submittedAt: i.submittedAt };
  return i;
}

/** Kinds the app may label an intent with; free text never reaches the table. */
export const INTENT_KINDS = [
  "supply",
  "withdraw",
  "pledge",
  "addCollateral",
  "withdrawCollateral",
  "borrow",
  "repay",
  "repayWithCollateral",
  "deleverage",
  "closeAccount",
  "claimFees",
  "approve",
  "swap",
] as const;
export type IntentKind = (typeof INTENT_KINDS)[number];
