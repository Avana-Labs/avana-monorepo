// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The monitor's own metrics in the Prometheus text format, served at GET /metrics with MONITOR_METRICS_TOKEN: open
// alerts by chain, signal and level; each chain's rounds (result, duration of the last one, the head it read, the last
// success); probe read failures; each keeper instance's last heartbeat and how many blocks it is behind the chain's
// head; the notices sent and each channel's delivery result. The label `keeper` names a keeper instance (Prometheus
// keeps `instance` for the scrape target). Counters of known label sets start at zero, so a rate has no gap.

import type { IncidentEntry, IncidentLog } from "./incidentLog.ts";
import type { KeeperInstance } from "./keeper.ts";
import { SIGNALS } from "./signals.ts";
import type { Alert } from "./types.ts";

export interface MetricsChain {
  readonly id: number;
  /** The chain key (`mainnet`, `base`), the `chain` label the keeper and the indexer use too. */
  readonly key: string;
  /** The names of the probes the chain runs. */
  readonly probes: readonly string[];
}

export interface RoundOutcome {
  readonly ok: boolean;
  readonly durationSeconds: number;
  /** Unix seconds the round ended. */
  readonly endedAt: number;
  /** The probes whose read failed (`RoundError`); empty when the round failed before the probes ran. */
  readonly failedProbes: readonly string[];
}

type Labels = readonly (readonly [string, string])[];

const escape = (v: string) => v.replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/"/g, '\\"');
const series = (name: string, labels: Labels, value: number | bigint) =>
  `${name}${labels.length > 0 ? `{${labels.map(([k, v]) => `${k}="${escape(v)}"`).join(",")}}` : ""} ${value.toString()}`;

/** A counter family: label values joined by `|` → count. */
class Counter {
  readonly values = new Map<string, { labels: Labels; value: number }>();

  constructor(readonly name: string, readonly help: string) {}

  inc(labels: Labels, by = 1): void {
    const k = labels.map(([, v]) => v).join("|");
    const cur = this.values.get(k);
    if (cur) cur.value += by;
    else this.values.set(k, { labels, value: by });
  }

  lines(): string[] {
    return [`# HELP ${this.name} ${this.help}`, `# TYPE ${this.name} counter`, ...[...this.values.values()].map((s) => series(this.name, s.labels, s.value))];
  }
}

const gauge = (name: string, help: string, rows: readonly (readonly [Labels, number | bigint])[]) => [`# HELP ${name} ${help}`, `# TYPE ${name} gauge`, ...rows.map(([l, v]) => series(name, l, v))];

export class MonitorMetrics {
  readonly #chains: ReadonlyMap<number, MetricsChain>;
  readonly #rounds = new Counter("monitor_rounds_total", "Rounds per chain by result (ok, failed).");
  readonly #probeFailures = new Counter("monitor_probe_read_failures_total", "Probe reads that failed, per chain and probe; the probe's open alerts were neither resolved nor re-sent.");
  readonly #notices = new Counter("monitor_notices_total", "Notices sent, per chain, signal, level and transition.");
  readonly #deliveries = new Counter("monitor_deliveries_total", "Notice deliveries per channel by result (ok, failed), after retries.");
  readonly #duration = new Map<number, number>();
  readonly #lastSuccess = new Map<number, number>();
  readonly #head = new Map<number, bigint>();

  constructor(chains: readonly MetricsChain[], readonly keepers: readonly KeeperInstance[], channels: readonly string[], readonly startedAt: number) {
    this.#chains = new Map(chains.map((c) => [c.id, c]));
    for (const c of chains) {
      for (const result of ["ok", "failed"]) this.#rounds.inc([["chain", c.key], ["result", result]], 0);
      for (const probe of c.probes) this.#probeFailures.inc([["chain", c.key], ["probe", probe]], 0);
    }
    for (const channel of channels) for (const result of ["ok", "failed"]) this.#deliveries.inc([["channel", channel], ["result", result]], 0);
  }

  #key(chainId: number): string {
    return this.#chains.get(chainId)?.key ?? String(chainId);
  }

  /** The head a round of the chain read. */
  head(chainId: number, block: bigint): void {
    this.#head.set(chainId, block);
  }

  round(chainId: number, r: RoundOutcome): void {
    const chain = this.#key(chainId);
    this.#rounds.inc([["chain", chain], ["result", r.ok ? "ok" : "failed"]]);
    this.#duration.set(chainId, r.durationSeconds);
    if (r.ok) this.#lastSuccess.set(chainId, r.endedAt);
    for (const probe of r.failedProbes) this.#probeFailures.inc([["chain", chain], ["probe", probe]]);
  }

  /** Counts one incident-log entry: the notice, and each channel's answer. */
  notice(e: IncidentEntry): void {
    this.#notices.inc([["chain", this.#key(e.chainId)], ["signal", e.signal], ["level", e.level], ["transition", e.transition]]);
    for (const d of e.deliveries) this.#deliveries.inc([["channel", d.channel], ["result", d.ok ? "ok" : "failed"]]);
  }

  /** The incident log, counting each entry once it is written. */
  countingLog(inner: IncidentLog): IncidentLog {
    return {
      write: (entry) => {
        inner.write(entry);
        this.notice(entry);
      },
    };
  }

  /** The text exposition, from the open alerts and each keeper instance's last heartbeat block. */
  render(open: readonly Alert[], heartbeat: (instance: string) => bigint | undefined): string {
    const chains = [...this.#chains.values()];
    const openCount = new Map<string, number>();
    for (const a of open) openCount.set(`${a.chainId}|${a.signal}|${a.level}`, (openCount.get(`${a.chainId}|${a.signal}|${a.level}`) ?? 0) + 1);
    const openRows = chains.flatMap((c) => SIGNALS.flatMap((s) => (["warn", "page"] as const).map((level) => [[["chain", c.key], ["signal", s.id], ["level", level]], openCount.get(`${c.id}|${s.id}|${level}`) ?? 0] as const)));

    const perChain = (m: ReadonlyMap<number, number | bigint>) => chains.filter((c) => m.has(c.id)).map((c) => [[["chain", c.key]], m.get(c.id)!] as const);
    const beats = this.keepers.flatMap((k) => {
      const b = heartbeat(k.name);
      return b === undefined ? [] : [{ k, b, head: this.#head.get(k.chainId) }];
    });
    const keeperLabels = (k: KeeperInstance): Labels => [["keeper", k.name], ["chain", this.#key(k.chainId)]];

    return `${[
      ...gauge("monitor_start_time_seconds", "Unix time the monitor process started.", [[[], this.startedAt]]),
      ...gauge("monitor_open_alerts", "Open alerts per chain, signal and level.", openRows),
      ...this.#rounds.lines(),
      ...gauge("monitor_round_duration_seconds", "Duration of the chain's last round, failed or not.", perChain(this.#duration)),
      ...gauge("monitor_round_last_success_timestamp_seconds", "Unix time the chain's last successful round ended.", perChain(this.#lastSuccess)),
      ...gauge("monitor_head_block", "The head block the chain's last round read.", perChain(this.#head)),
      ...this.#probeFailures.lines(),
      ...gauge("monitor_keeper_heartbeat_block", "The last block each keeper instance reported as processed (heartbeat or alert).", beats.map(({ k, b }) => [keeperLabels(k), b] as const)),
      ...gauge(
        "monitor_keeper_heartbeat_age_blocks",
        "Blocks between the chain's last head read and the keeper instance's last heartbeat; 3 or more pages M-09.",
        beats.filter((x) => x.head !== undefined).map(({ k, b, head }) => [keeperLabels(k), head! > b ? head! - b : 0n] as const),
      ),
      ...this.#notices.lines(),
      ...this.#deliveries.lines(),
    ].join("\n")}\n`;
  }
}
