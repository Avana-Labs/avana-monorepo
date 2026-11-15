// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Private submission and the per-block follow-up of every pending transaction. Every first send, replacement and
// cancellation goes through the same private channel: builder endpoints on Ethereum, the sequencer endpoint through
// two providers on Base. Nothing is ever sent to a public mempool (Q-345).

import type { Hex } from "viem";
import type { TxPlan } from "../types.ts";

/** Sends one signed transaction to every private endpoint of the chain; resolves when at least one accepted it. */
export async function sendPrivate(endpoints: readonly string[], raw: Hex, post: (url: string, body: unknown) => Promise<unknown>): Promise<string[]> {
  if (endpoints.length === 0) throw new Error("no private endpoint configured");
  const body = { jsonrpc: "2.0", id: 1, method: "eth_sendRawTransaction", params: [raw] };
  const results = await Promise.allSettled(endpoints.map((url) => post(url, body)));
  const accepted = endpoints.filter((_, i) => results[i]!.status === "fulfilled");
  if (accepted.length === 0) throw new Error("every private endpoint refused the transaction");
  return accepted;
}

export interface Pending {
  readonly plan: TxPlan;
  readonly nonce: number;
  readonly hash: Hex;
  readonly sentBlock: bigint;
  readonly fees: { readonly maxFeePerGas: bigint; readonly maxPriorityFeePerGas: bigint };
  readonly replacements: number;
}

export type FollowUp =
  | { readonly action: "done" }
  | { readonly action: "wait" }
  | { readonly action: "replace" }
  | { readonly action: "rebuild" }
  | { readonly action: "cancel" };

/**
 * What to do with a pending transaction in a new block (services/README.md, Submission > Retries):
 * - mined (its nonce consumed): done; the in-flight flag and reservations are released;
 * - before its deadline, still simulating successfully and not included: replace at the same nonce, fees +15 %;
 * - before its deadline, simulation failing: wait (another caller may have won; the next scan decides);
 * - past its deadline, account still liquidatable: rebuild from a fresh preview at the same nonce;
 * - past its deadline and not liquidatable, nonce unconsumed 2 blocks later: cancel with a zero-value
 *   transfer from the signer to itself at that nonce, through the same private channel.
 * A poke carries no deadline: it is replaced while its simulation still changes state, otherwise cancelled.
 * The rule applies from the block after the send: state read at the send's own block cannot show it mined, and a
 * simulation there after a node already included it (anvil mines at once) would cancel a consumed nonce.
 */
export function followUp(
  p: Pending,
  now: { blockNumber: bigint; timestamp: bigint },
  nonceConsumed: boolean,
  simulationOk: boolean,
  stillDue: boolean,
): FollowUp {
  if (now.blockNumber <= p.sentBlock) return { action: "wait" };
  if (nonceConsumed) return { action: "done" };
  const expired = p.plan.deadline !== null && now.timestamp > p.plan.deadline;
  if (!expired) return simulationOk ? { action: "replace" } : p.plan.deadline === null ? { action: "cancel" } : { action: "wait" };
  if (stillDue) return { action: "rebuild" };
  return now.blockNumber >= p.sentBlock + 2n ? { action: "cancel" } : { action: "wait" };
}
