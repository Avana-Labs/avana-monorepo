// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The pinned multicall the snapshot reader runs on, and the two ways it runs a batch: every call must succeed, or a
// call may revert and reads as null.

import type { DecimalString } from "../export.ts";
import type { Address } from "./types.ts";

export interface ContractCall {
  readonly address: Address;
  readonly abi: readonly unknown[];
  readonly functionName: string;
  readonly args?: readonly unknown[];
}

export type CallResult = { readonly status: "success"; readonly result: unknown } | { readonly status: "failure"; readonly error: unknown };

/**
 * A multicall pinned to one block. The indexer wraps Ponder's `context.client` (pinned to the sample block), Convex
 * a viem client with `blockNumber`.
 */
export interface ViewClient {
  multicall(calls: readonly ContractCall[]): Promise<readonly CallResult[]>;
}

export const ZERO: Address = "0x0000000000000000000000000000000000000000";
export const s = (x: bigint | number): DecimalString => x.toString(10);
export const lower = (a: string): Address => a.toLowerCase() as Address;

/** Runs calls that must all succeed; one failure fails the snapshot (no partial pages of numbers). */
export async function all(client: ViewClient, calls: readonly ContractCall[]): Promise<unknown[]> {
  if (calls.length === 0) return [];
  const out = await client.multicall(calls);
  return out.map((r, i) => {
    if (r.status !== "success") throw new Error(`${calls[i]!.functionName} on ${calls[i]!.address} reverted: ${String(r.error)}`);
    return r.result;
  });
}

/** Runs calls that may revert (a Lens view that refuses an asset); a failure is null. */
export async function some(client: ViewClient, calls: readonly ContractCall[]): Promise<unknown[]> {
  if (calls.length === 0) return [];
  return (await client.multicall(calls)).map((r) => (r.status === "success" ? r.result : null));
}

/** Distinct values in first-seen order. */
export function uniq<T>(xs: readonly T[]): T[] {
  return [...new Set(xs)];
}
