// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Types shared by the pipeline and the jobs. Amounts are bigint everywhere.

import type { Address, Hex } from "viem";
import type { ChainConfig } from "./config.ts";
import type { ChainReader } from "./chain/reads.ts";
import type { Revert } from "./jobs/failureReasons.ts";

export type JobKind = "liquidation" | "settlePending" | "oraclePoke" | "breakerPoke" | "configPoke";

/** Why a candidate was not acted on in this block; logged with the block and published for liquidations. */
export type SkipReason =
  | "healthy"
  | "zeroCollateral"
  | "notInShard"
  | "inFlight"
  | "marketNotLiquidatable"
  | "priceTooOld"
  | "disagreementPause"
  | "sequencerDown"
  | "graceAboveThreshold"
  | "noPricedDebtReserve"
  | "previewGateFalse"
  | "nothingPending"
  | "notDue"
  | "conditionFalse"
  | "simulationFailed"
  | "helperFrozen"
  | "codeMismatch"
  | "halted"
  | "observeOnly"
  | "insufficientInventory";

/** Everything a decision in block `blockNumber` may read; every read goes through `reader`, pinned to that block. */
export interface BlockContext {
  readonly config: ChainConfig;
  readonly blockNumber: bigint;
  readonly blockTimestamp: bigint;
  readonly reader: ChainReader;
}

/** A contract the call reaches, checked against the manifest before signing (Q-219). */
export type CodeTarget =
  | { readonly kind: "upgradeable"; readonly address: Address; readonly implementation: Address }
  | { readonly kind: "immutable"; readonly address: Address; readonly codeHash: Hex };

/** Inventory a pending transaction may pull, per debt asset (Q-336). */
export interface Reservation {
  readonly asset: Address;
  readonly amount: bigint;
}

/** A transaction ready to simulate: no signature, no nonce, no fees yet. */
export interface TxPlan {
  readonly job: JobKind;
  /** Account key `chainId:spoke:proxy`, market ID or oracle address: the in-flight flag and logs use it. */
  readonly subject: string;
  readonly to: Address;
  readonly data: Hex;
  /** Unix seconds after which the call reverts on-chain; null for pokes, which carry no deadline. */
  readonly deadline: bigint | null;
  readonly reservations: readonly Reservation[];
  readonly targets: readonly CodeTarget[];
  /** Parameters logged in observe-only mode and in the public failure log. */
  readonly params: Readonly<Record<string, unknown>>;
}

export type Check<D> =
  | { readonly act: true; readonly decision: D }
  | { readonly act: false; readonly reason: SkipReason; readonly detail?: string };

/**
 * One job of the keeper. Every job runs the same pipeline (pipeline.ts):
 * discover (cache, indexer) → check (live reads at the block) → build → guards → simulate → private send.
 */
export interface Job<C, D> {
  readonly kind: JobKind;
  /** Candidates from the cache; cached values only choose what to read. */
  discover(ctx: BlockContext): Promise<readonly C[]>;
  /** Re-verifies eligibility from live reads pinned to the block. */
  check(ctx: BlockContext, candidate: C): Promise<Check<D>>;
  build(ctx: BlockContext, decision: D): Promise<TxPlan>;
  /** Runs one candidate's whole pass (check to send) under the job's own exclusion, such as the account in-flight flag. */
  exclusive?(candidate: C, pass: () => Promise<void>): Promise<void>;
  /** Acts on a simulation that reverted (in the build or before the send), by the failure-reason table. */
  onFailure?(ctx: BlockContext, subject: string, revert: Revert): Promise<void> | void;
}
