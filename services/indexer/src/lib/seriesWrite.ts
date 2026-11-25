// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Writes one observation into the hourly and daily buckets of a scope. Sampled scopes keep the bucket's first
// sample, so a replayed or second sample in the same bucket changes nothing; pool buckets merge by their rules.

import { type DecimalString, type Resolution, type SeriesScopeKind, bucketEnd, bucketStart, mergeValues } from "@avana/services-common";
import type { Context } from "ponder:registry";
import schema from "ponder:schema";

export interface Observation {
  readonly chainId: number;
  readonly kind: SeriesScopeKind;
  readonly key: string;
  readonly timestamp: number;
  readonly blockNumber: bigint;
  readonly values: Readonly<Record<string, DecimalString>>;
  /** Resolutions to write; positions are kept daily only. */
  readonly resolutions?: readonly Resolution[];
}

export async function writeObservation(context: Context, o: Observation): Promise<void> {
  for (const resolution of o.resolutions ?? (["hour", "day"] as const)) {
    const start = bucketStart(o.timestamp, resolution);
    const row = {
      chainId: o.chainId,
      scopeKind: o.kind,
      scopeKey: o.key,
      resolution,
      bucketStart: start,
      bucketEnd: bucketEnd(start, resolution),
      blockNumber: o.blockNumber,
      values: o.values,
    };
    if (o.kind === "pool") {
      await context.db
        .insert(schema.seriesPoint)
        .values(row)
        .onConflictDoUpdate((stored) => ({
          values: mergeValues("pool", stored.values as Record<string, DecimalString>, o.values),
          blockNumber: o.blockNumber,
        }));
    } else {
      await context.db.insert(schema.seriesPoint).values(row).onConflictDoNothing();
    }
  }
}
