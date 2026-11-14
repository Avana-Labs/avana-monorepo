// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One evaluation round of one chain: read the snapshot at the head on the primary provider, judge it, confirm its
// pages on the second provider at the same block, add the keeper's findings, then send and log every notice. The
// reads are injected, so the round runs the same against a test chain.

import type { ChainSnapshot } from "@avana/services-common/views";
import type { AlertBook } from "./alertBook.ts";
import { confirmPages } from "./confirm.ts";
import { type IncidentLog, incidentEntry } from "./incidentLog.ts";
import type { KeeperFeed } from "./keeper.ts";
import { type Channel, type RetryPolicy, DEFAULT_RETRY, deliver } from "./notify/channels.ts";
import { type RoutingTable, channelsOf, recipientsOf } from "./routing.ts";
import { type SnapshotMemory, evaluateSnapshot } from "./rules/snapshot.ts";
import type { Notice } from "./types.ts";

export interface ChainReads {
  readonly chainId: number;
  head(): Promise<{ number: bigint; timestamp: number }>;
  /** The snapshot at `block` on the primary provider. */
  primary(block: { number: bigint; timestamp: number }): Promise<ChainSnapshot>;
  /** The same snapshot read on the second provider. */
  second(block: { number: bigint; timestamp: number }): Promise<ChainSnapshot>;
}

export interface RoundDeps {
  readonly book: AlertBook;
  readonly memory: SnapshotMemory;
  readonly feed: KeeperFeed;
  readonly routing: RoutingTable;
  readonly channels: ReadonlyMap<string, Channel>;
  readonly log: IncidentLog;
  readonly retry?: RetryPolicy;
}

/** Sends one notice to its channels and logs it with every channel's answer. */
export async function dispatch(n: Notice, deps: Pick<RoundDeps, "routing" | "channels" | "log" | "retry">): Promise<void> {
  const channels = channelsOf(n, deps.routing).map((name) => {
    const c = deps.channels.get(name);
    if (!c) throw new Error(`routing names channel ${name}, which is not configured`);
    return c;
  });
  const deliveries = await deliver(n, channels, deps.retry ?? DEFAULT_RETRY);
  deps.log.write(incidentEntry(n, recipientsOf(n), deliveries));
}

/** One round; returns the notices it sent. A failed snapshot read throws, after the keeper findings were handled. */
export async function runRound(reads: ChainReads, deps: RoundDeps): Promise<Notice[]> {
  const head = await reads.head();
  const sent: Notice[] = [];
  const send = async (ns: Notice[]) => {
    for (const n of ns) {
      await dispatch(n, deps);
      sent.push(n);
    }
  };
  // Keeper findings first: they need only the head, so a broken snapshot read never hides a silent keeper.
  await send(deps.book.apply({ source: "keeper", chainId: reads.chainId, blockNumber: head.number, timestamp: head.timestamp, findings: deps.feed.findings(reads.chainId, head.number), complete: true }));

  const snap = await reads.primary(head);
  const findings = await confirmPages(evaluateSnapshot(snap, deps.memory), snap, () => reads.second(head));
  await send(deps.book.apply({ source: "snapshot", chainId: reads.chainId, blockNumber: head.number, timestamp: head.timestamp, findings, complete: true }));
  return sent;
}
