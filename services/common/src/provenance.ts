// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Provenance of every indexed row: which log produced it, in which block, under which hash (TEST-061, TEST-143).

import type { Hex } from "viem";

export interface Provenance {
  readonly chainId: number;
  readonly blockNumber: bigint;
  readonly blockHash: Hex;
  /** Unix seconds of the block. */
  readonly blockTimestamp: bigint;
  readonly txHash: Hex;
  readonly logIndex: number;
}

/** The unique key of a log across chains: `chainId + txHash + logIndex`. */
export function logKey(p: Pick<Provenance, "chainId" | "txHash" | "logIndex">): string {
  return `${p.chainId}:${p.txHash.toLowerCase()}:${p.logIndex}`;
}

/** Total order of logs on one chain; exports and replays sort by it. */
export function compareProvenance(a: Provenance, b: Provenance): number {
  if (a.blockNumber !== b.blockNumber) return a.blockNumber < b.blockNumber ? -1 : 1;
  return a.logIndex - b.logIndex;
}

/** Account key `chainId + Spoke + proxy`; one PositionProxy per (wallet, CDP Spoke, market). */
export function accountKey(chainId: number, spoke: Hex, proxy: Hex): string {
  return `${chainId}:${spoke.toLowerCase()}:${proxy.toLowerCase()}`;
}

/** Collateral record key `chainId + Collateralization + recordId`. */
export function recordKey(chainId: number, collateralization: Hex, recordId: bigint): string {
  return `${chainId}:${collateralization.toLowerCase()}:${recordId}`;
}

/** Debt reserve key `chainId + Spoke + debtReserveId`. */
export function debtReserveKey(chainId: number, spoke: Hex, debtReserveId: bigint): string {
  return `${chainId}:${spoke.toLowerCase()}:${debtReserveId}`;
}
