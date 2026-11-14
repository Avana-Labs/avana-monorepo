// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A probe reads one group of signals' inputs at a block, judges them, and says which raw values each finding's
// subject was judged from. The round reads every probe on the primary provider and, for the probes with a page,
// again on the second provider at the same block: a page whose evidence differs is sent as a warn.

import type { ChainInfo, ServiceManifest } from "@avana/services-common";
import type { ChainSnapshot, ViewClient } from "@avana/services-common/views";
import type { Address, Hex } from "viem";
import type { Finding } from "./types.ts";

export interface RawLog {
  readonly address: Address;
  readonly topics: readonly Hex[];
  readonly data: Hex;
  readonly blockNumber: bigint;
  readonly transactionHash: Hex;
  readonly logIndex: number;
}

/** An `eth_call` state override: replaced code and storage slots of one account. */
export interface Override {
  readonly address: Address;
  readonly code?: Hex;
  readonly stateDiff?: readonly { readonly slot: Hex; readonly value: Hex }[];
}

export type CallOutcome = { readonly ok: true; readonly data: Hex } | { readonly ok: false; readonly error: string };

/** Reads that a multicall cannot make, pinned to the context's block (logs up to it). */
export interface RawRpc {
  /** Logs of `addresses` whose first topic is one of `topic0s`, in [fromBlock, toBlock]. */
  getLogs(addresses: readonly Address[], topic0s: readonly Hex[], fromBlock: bigint, toBlock: bigint): Promise<RawLog[]>;
  getStorageAt(address: Address, slot: Hex): Promise<Hex>;
  /** A simulated call from `from` at the block, with state overrides; never sent. A revert is an outcome, not a throw. */
  call(from: Address, to: Address, data: Hex, overrides?: readonly Override[]): Promise<CallOutcome>;
}

export interface ReadContext {
  readonly chain: ChainInfo;
  readonly manifest: ServiceManifest;
  readonly block: { readonly number: bigint; readonly timestamp: number };
  readonly views: ViewClient;
  readonly rpc: RawRpc;
  /** This provider's snapshot at the block, shared by the probes. */
  readonly snapshot: ChainSnapshot;
}

export interface Probe<I = unknown> {
  /** The alert book's source key: open alerts of this probe resolve when a later evaluation no longer reports them. */
  readonly name: string;
  read(ctx: ReadContext): Promise<I>;
  /** Judges one read; may keep state between blocks. Called once per round, on the primary provider's read only. */
  evaluate(input: I, block: ReadContext["block"]): Finding[];
  /** The raw values a subject was judged from, as text; null when none. */
  evidence(input: I, subject: string): string | null;
  /** The state to keep across a restart (state.ts); omitted by a stateless probe. */
  save?(): unknown;
  /** Restores what `save` returned before the first round. */
  restore?(state: unknown): void;
}

/** Stable text of a value with bigints, for evidence comparison. */
export const text = (v: unknown): string => JSON.stringify(v, (_, x) => (typeof x === "bigint" ? x.toString(10) : x));

/**
 * Keeps each page whose evidence reads the same on the second provider and turns the others into warns. With the
 * second read failing the page still goes out, marked unconfirmed (one dead endpoint must not hide an emergency).
 */
export function confirmWith<I>(probe: Probe<I>, findings: readonly Finding[], primary: I, second: I | Error): Finding[] {
  return findings.map((f) => {
    if (f.level !== "page") return f;
    if (second instanceof Error) return { ...f, detail: { ...f.detail, note: `unconfirmed, second provider unavailable: ${second.message}` } };
    const mine = probe.evidence(primary, f.subject);
    if (mine !== null && mine === probe.evidence(second, f.subject)) return f;
    return { ...f, level: "warn", detail: { ...f.detail, note: "not confirmed on the second provider" } };
  });
}
