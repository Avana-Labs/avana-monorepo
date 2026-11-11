// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Provenance and the event log row every handler writes first. A handler that updates an entity table also
// stores the block hash and log index of the log that last changed it.

import type { Provenance } from "@avana/services-common";
import type { Context } from "ponder:registry";
import schema from "ponder:schema";
import type { Hex } from "viem";

/** The fields of a Ponder log event the indexer reads. */
export interface LogEventLike {
  readonly args: Readonly<Record<string, unknown>>;
  readonly block: { readonly number: bigint; readonly hash: Hex; readonly timestamp: bigint };
  readonly log: { readonly logIndex: number; readonly address: Hex };
  readonly transaction: { readonly hash: Hex };
}

export function provenance(event: LogEventLike, context: Context): Provenance {
  return {
    chainId: context.chain.id,
    blockNumber: event.block.number,
    blockHash: event.block.hash,
    blockTimestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    logIndex: event.log.logIndex,
  };
}

/** JSON-safe copy of decoded arguments: bigints as decimal strings, addresses and hex lower-case. */
export function normaliseArgs(value: unknown): unknown {
  if (typeof value === "bigint") return value.toString(10);
  if (typeof value === "string") return value.startsWith("0x") ? value.toLowerCase() : value;
  if (Array.isArray(value)) return value.map(normaliseArgs);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, normaliseArgs(v)]));
  }
  return value;
}

/**
 * Writes the log row. A replay of the same log (restart, reorg replay) hits the primary key
 * `chainId + txHash + logIndex` and changes nothing, so every handler is idempotent at this step.
 */
export async function recordLog(event: LogEventLike, context: Context, kind: string): Promise<Provenance> {
  const p = provenance(event, context);
  await context.db
    .insert(schema.eventLog)
    .values({
      chainId: p.chainId,
      txHash: p.txHash,
      logIndex: p.logIndex,
      blockNumber: p.blockNumber,
      blockHash: p.blockHash,
      blockTimestamp: p.blockTimestamp,
      address: event.log.address.toLowerCase() as Hex,
      kind,
      args: normaliseArgs(event.args),
    })
    .onConflictDoNothing();
  return p;
}
