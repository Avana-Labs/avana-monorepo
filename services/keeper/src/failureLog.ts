// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Public failure log (duty 6). A transaction that reverts emits no events, so every failed simulation that blocked a
// due call, every reverted, replaced or cancelled attempt and every observe-only call is published from these
// structured records, with its block, parameters and revert reason.

import type { Hex } from "viem";
import type { JobKind, SkipReason } from "./types.ts";

export type AttemptOutcome =
  | "wouldSend"
  | "sent"
  | "simulationFailed"
  | "reverted"
  | "replaced"
  | "cancelled"
  | "expired"
  | "included"
  | "skipped"
  /** A mined transaction whose block a reorg removed: it is pending again. */
  | "reorged"
  /** A send or replacement refused because its worst-case cost passes the chain's gas ceiling. */
  | "aboveGasCeiling"
  /** A replacement, cancellation or nonce-closing send every private endpoint refused; the next block decides again. */
  | "sendRefused";

export interface AttemptRecord {
  readonly at: string;
  readonly chainId: number;
  readonly blockNumber: string;
  readonly job: JobKind;
  readonly subject: string;
  readonly outcome: AttemptOutcome;
  readonly reason?: SkipReason | string;
  /** 4-byte selector, decoded name and arguments of the revert, when there is one (M-10 counts by name). */
  readonly revert?: { readonly selector: Hex; readonly name: string; readonly args?: readonly string[] };
  readonly txHash?: Hex;
  readonly nonce?: number;
  readonly params: Readonly<Record<string, string>>;
}

/** Bigint-safe structured line on stdout; the log shipper sends it off the host. */
export function logAttempt(record: AttemptRecord): void {
  process.stdout.write(`${JSON.stringify({ type: "keeper.attempt", ...record })}\n`);
}

export function stringifyParams(params: Readonly<Record<string, unknown>>): Record<string, string> {
  return Object.fromEntries(Object.entries(params).map(([k, v]) => [k, typeof v === "bigint" ? v.toString(10) : JSON.stringify(v, (_, x) => (typeof x === "bigint" ? x.toString(10) : x))]));
}
