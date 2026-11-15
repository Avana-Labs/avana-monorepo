// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The keeper's Prometheus text at GET /metrics (KEEPER_METRICS_PORT). Dashboards are built on these names and labels;
// keep them stable. `chain` is the chain key of @avana/services-common (mainnet, base, sepolia, baseSepolia, anvil).
//
//   keeper_mode{chain,mode}                     1 for the effective mode: active, observe or halted
//   keeper_head_block{chain}                    last head this instance finished processing (the monitor heartbeat)
//   keeper_indexer_block{chain}                 last block the indexer stream reported fully handled
//   keeper_rpc_backfill_block{chain}            block the RPC log backfill has read to on both providers
//   keeper_discovered_accounts{chain}           accounts in the cache (the union of both discovery sources)
//   keeper_discovery_one_sided{chain,only}      accounts only one source holds (M-30); only = indexer | rpc
//   keeper_alerts_open{chain,signal,level}      alerts raised for the last processed head (a held condition is
//                                               re-sent every block, so this is what is open at the monitor)
//   keeper_alerts_total{chain,signal,level}     alerts raised since the process started (counter)
//
// A gauge with no value yet (no head processed, a source not read) is left out rather than written as 0.

import type { Alert } from "./monitoring/alerts.ts";

/** What one chain's loop has reported; updated by main.ts, read at each scrape. */
export class ChainMetrics {
  head: bigint | null = null;
  indexedBlock: bigint | null = null;
  rpcThrough: bigint | null = null;
  accounts: number | null = null;
  oneSided: { indexer: number; rpc: number } | null = null;
  readonly #total = new Map<string, number>();
  /** Alerts of the head being processed; becomes `#open` when the head is reported processed. */
  #building: { block: bigint; counts: Map<string, number> } = { block: -1n, counts: new Map() };
  #open = new Map<string, number>();

  /** Counts one alert sent; called by the alert sink for every alert, before it is posted. */
  alert(a: Alert): void {
    const key = `${a.signal}|${a.level}`;
    this.#total.set(key, (this.#total.get(key) ?? 0) + 1);
    if (a.blockNumber > this.#building.block) this.#building = { block: a.blockNumber, counts: new Map() };
    if (a.blockNumber === this.#building.block) inc(this.#building.counts, key);
    // An alert raised outside the pass (the gas ceiling) for the head already processed.
    if (a.blockNumber === this.head) inc(this.#open, key);
  }

  /** The head is processed: its alerts become the open set. */
  processed(head: bigint): void {
    this.head = head;
    this.#open = this.#building.block === head ? new Map(this.#building.counts) : new Map();
  }

  open(): ReadonlyMap<string, number> {
    return this.#open;
  }

  total(): ReadonlyMap<string, number> {
    return this.#total;
  }
}

const inc = (m: Map<string, number>, key: string) => m.set(key, (m.get(key) ?? 0) + 1);

export interface ChainSample {
  readonly chain: string;
  readonly mode: "active" | "observe" | "halted";
  readonly metrics: ChainMetrics;
}

/** Label value escaping of the text format: backslash, double quote and newline. */
const esc = (v: string) => v.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n");
const labels = (l: Readonly<Record<string, string>>) => `{${Object.entries(l).map(([k, v]) => `${k}="${esc(v)}"`).join(",")}}`;

/** The text format of every chain's metrics; each family's samples are written together under its HELP and TYPE. */
export function renderMetrics(chains: readonly ChainSample[]): string {
  const out: string[] = [];
  const family = (name: string, type: "gauge" | "counter", help: string, samples: readonly [Readonly<Record<string, string>>, bigint | number][]) => {
    out.push(`# HELP ${name} ${help}`, `# TYPE ${name} ${type}`);
    for (const [l, v] of samples) out.push(`${name}${labels(l)} ${v.toString(10)}`);
  };
  const each = <T>(pick: (c: ChainSample) => T | null, row: (c: ChainSample, v: T) => [Record<string, string>, bigint | number][]) =>
    chains.flatMap((c) => {
      const v = pick(c);
      return v === null ? [] : row(c, v);
    });
  const bySignal = (c: ChainSample, m: ReadonlyMap<string, number>): [Record<string, string>, number][] =>
    [...m.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([key, n]) => {
      const [signal, level] = key.split("|") as [string, string];
      return [{ chain: c.chain, signal, level }, n];
    });

  family("keeper_mode", "gauge", "Effective mode of the instance on the chain (1 for the current mode).", chains.map((c) => [{ chain: c.chain, mode: c.mode }, 1]));
  family("keeper_head_block", "gauge", "Last head the instance finished processing.", each((c) => c.metrics.head, (c, v) => [[{ chain: c.chain }, v]]));
  family("keeper_indexer_block", "gauge", "Last block the indexer stream reported fully handled.", each((c) => c.metrics.indexedBlock, (c, v) => [[{ chain: c.chain }, v]]));
  family("keeper_rpc_backfill_block", "gauge", "Block the RPC log backfill has read to on both providers.", each((c) => c.metrics.rpcThrough, (c, v) => [[{ chain: c.chain }, v]]));
  family("keeper_discovered_accounts", "gauge", "Accounts in the keeper's cache (union of the indexer stream and the RPC backfill).", each((c) => c.metrics.accounts, (c, v) => [[{ chain: c.chain }, v]]));
  family("keeper_discovery_one_sided", "gauge", "Accounts only one discovery source holds, by the source that holds them (M-30).", each((c) => c.metrics.oneSided, (c, v) => [[{ chain: c.chain, only: "indexer" }, v.indexer], [{ chain: c.chain, only: "rpc" }, v.rpc]]));
  family("keeper_alerts_open", "gauge", "Alerts raised for the last processed head, by signal and level.", chains.flatMap((c) => bySignal(c, c.metrics.open())));
  family("keeper_alerts_total", "counter", "Alerts raised since the process started, by signal and level.", chains.flatMap((c) => bySignal(c, c.metrics.total())));
  return `${out.join("\n")}\n`;
}
