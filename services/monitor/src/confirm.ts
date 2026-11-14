// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The evidence of the snapshot probe: the rows a finding's subject was judged from. A page is sent only when they
// read the same on the second RPC provider at the same block (services/README.md: "re-checked against a second RPC
// source before paging"); see probe.ts.

import type { ChainSnapshot } from "@avana/services-common/views";
import type { Probe } from "./probe.ts";
import { SnapshotMemory, evaluateSnapshot } from "./rules/snapshot.ts";

/** The snapshot rows a finding's subject was judged from, as text; null for a subject no row backs. */
export function rowsFor(snap: ChainSnapshot, subject: string): string | null {
  const [kind, ...rest] = subject.split(":");
  let rows: readonly unknown[];
  switch (kind) {
    case "market":
      rows = snap.markets.filter((m) => m.marketId === rest[0]);
      break;
    case "reserve":
      rows = snap.spokeReserves.filter((r) => r.spoke === rest[0] && r.reserveId === rest[1]);
      break;
    case "hubAsset":
      rows = snap.hubAssets.filter((a) => a.hub === rest[0] && a.assetId === rest[1]);
      break;
    case "slice":
      rows = snap.slices.filter((s) => s.hub === rest[0] && s.assetId === rest[1] && s.spoke === rest[2]);
      break;
    case "hub":
      rows = snap.hubs.filter((h) => h.hub === rest[0]);
      break;
    default:
      return null;
  }
  return rows.length > 0 ? JSON.stringify(rows) : null;
}

/** The snapshot rules as a probe: the round's snapshot is its input, its rows are the evidence. */
export function snapshotProbe(memory: SnapshotMemory = new SnapshotMemory()): Probe<ChainSnapshot> {
  return { name: "snapshot", read: async (ctx) => ctx.snapshot, evaluate: (snap) => evaluateSnapshot(snap, memory), evidence: rowsFor };
}
