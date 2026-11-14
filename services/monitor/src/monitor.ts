// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One evaluation round of one chain: the keeper's findings at the head, then every probe read at the head on the
// primary provider and judged, the pages of each probe confirmed by reading it again on the second provider at the
// same block, then every notice sent and logged. A probe that fails to read does not stop the others; the round
// reports the failures after sending what it could. Reads are injected, so the round runs the same on a test chain.

import type { ChainInfo, ServiceManifest } from "@avana/services-common";
import type { ChainSnapshot, ViewClient } from "@avana/services-common/views";
import type { AlertBook } from "./alertBook.ts";
import { type IncidentLog, incidentEntry } from "./incidentLog.ts";
import type { KeeperFeed } from "./keeper.ts";
import { type Channel, type RetryPolicy, DEFAULT_RETRY, deliver } from "./notify/channels.ts";
import { type Probe, type RawRpc, type ReadContext, confirmWith } from "./probe.ts";
import { type RoutingTable, channelsOf, recipientsOf } from "./routing.ts";
import type { Finding, Notice } from "./types.ts";

export interface Block {
  readonly number: bigint;
  readonly timestamp: number;
}

/** One RPC provider's reads, pinned to a block. */
export interface ProviderReads {
  snapshot(block: Block): Promise<ChainSnapshot>;
  views(block: Block): ViewClient;
  rpc(block: Block): RawRpc;
}

export interface ChainReads {
  readonly chain: ChainInfo;
  readonly manifest: ServiceManifest;
  head(): Promise<Block>;
  readonly primary: ProviderReads;
  readonly second: ProviderReads;
}

export interface RoundDeps {
  readonly book: AlertBook;
  readonly feed: KeeperFeed;
  readonly probes: readonly Probe[];
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

async function context(reads: ChainReads, p: ProviderReads, block: Block): Promise<ReadContext> {
  const snapshot = await p.snapshot(block);
  if (snapshot.blockNumber !== block.number.toString(10)) throw new Error(`snapshot read block ${snapshot.blockNumber}, not ${block.number}`);
  return { chain: reads.chain, manifest: reads.manifest, block, views: p.views(block), rpc: p.rpc(block), snapshot };
}

export class RoundError extends Error {
  constructor(readonly failures: readonly { readonly probe: string; readonly error: string }[]) {
    super(failures.map((f) => `${f.probe}: ${f.error}`).join("; "));
  }
}

/** One round; returns the notices it sent. Throws `RoundError` naming the probes that could not be read. */
export async function runRound(reads: ChainReads, deps: RoundDeps): Promise<Notice[]> {
  const head = await reads.head();
  const chainId = reads.chain.id;
  const sent: Notice[] = [];
  const send = async (source: string, findings: readonly Finding[]) => {
    for (const n of deps.book.apply({ source, chainId, blockNumber: head.number, timestamp: head.timestamp, findings, complete: true })) {
      await dispatch(n, deps);
      sent.push(n);
    }
  };
  // Keeper findings first: they need only the head, so a broken read never hides a silent keeper.
  await send("keeper", deps.feed.findings(chainId, head.number));

  const ctx = await context(reads, reads.primary, head);
  const failures: { probe: string; error: string }[] = [];
  const judged: { probe: Probe; input: unknown; findings: Finding[] }[] = [];
  for (const probe of deps.probes) {
    try {
      const input = await probe.read(ctx);
      judged.push({ probe, input, findings: probe.evaluate(input, head) });
    } catch (err) {
      failures.push({ probe: probe.name, error: err instanceof Error ? err.message : String(err) });
    }
  }

  let second: Promise<ReadContext> | null = null;
  for (const j of judged) {
    let findings = j.findings;
    if (findings.some((f) => f.level === "page")) {
      second ??= context(reads, reads.second, head);
      let input2: unknown;
      try {
        input2 = await j.probe.read(await second);
      } catch (err) {
        input2 = err instanceof Error ? err : new Error(String(err));
      }
      findings = confirmWith(j.probe, findings, j.input, input2);
    }
    await send(j.probe.name, findings);
  }
  if (failures.length > 0) throw new RoundError(failures);
  return sent;
}
