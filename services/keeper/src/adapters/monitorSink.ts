// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Alerts and heartbeats posted to the monitoring service (services/monitor, `/v1/keeper/alerts` and
// `/v1/keeper/heartbeat`), one monitor instance per chain, with that instance's bearer token. The monitor holds an alert
// open while it keeps arriving and pages the keeper's on-call engineer when the heartbeat falls 3 blocks behind.
//
// Posting never blocks the chain loop: lines are queued and flushed in the background, one request at a time. A failed
// post keeps its lines and is retried on the next alert or heartbeat (every block), so a monitor outage loses nothing
// but the oldest lines beyond `maxQueue`. Lines the monitor refuses (422) are logged and dropped, never retried.

import type { Alert, AlertSink } from "../monitoring/alerts.ts";

export interface MonitorTarget {
  readonly url: string;
  /** The instance name the monitor knows this keeper by on this chain (MONITOR_KEEPER_INSTANCES). */
  readonly instance: string;
  readonly token: string;
}

export interface MonitorSinkDeps {
  readonly fetch?: typeof fetch;
  /** Structured log line (`keeper.monitorSink`): failures, refusals and dropped lines. */
  readonly log: (record: Record<string, unknown>) => void;
  readonly maxQueue?: number;
  /** Lines per request. */
  readonly batch?: number;
}

export interface MonitorSink extends AlertSink {
  /** Records the block this instance has processed; only the latest is posted. */
  heartbeat(blockNumber: bigint): void;
  /** Resolves when the queue is empty or the current attempt has failed (tests and shutdown). */
  flush(): Promise<void>;
}

interface Line {
  readonly signal: string;
  readonly level: string;
  readonly chainId: number;
  readonly blockNumber: string;
  readonly subject: string;
  readonly detail: Readonly<Record<string, string>>;
}

export function monitorSink(target: MonitorTarget, deps: MonitorSinkDeps): MonitorSink {
  const doFetch = deps.fetch ?? fetch;
  const maxQueue = deps.maxQueue ?? 1_000;
  const batch = deps.batch ?? 200;
  const base = target.url.replace(/\/+$/, "");
  const queue: Line[] = [];
  let beat: bigint | null = null;
  let running: Promise<void> | null = null;
  let failing = false;

  const post = async (path: string, body: unknown) => {
    const res = await doFetch(`${base}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${target.token}` },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(5_000),
    });
    const text = await res.text();
    return { status: res.status, body: text };
  };

  const fail = (what: string, err: unknown) => {
    // Logged once per outage, then once when it ends.
    if (!failing) deps.log({ type: "keeper.monitorSink", event: "failed", instance: target.instance, what, error: String(err) });
    failing = true;
  };

  async function drain(): Promise<void> {
    while (queue.length > 0 || beat !== null) {
      if (queue.length > 0) {
        const lines = queue.slice(0, batch);
        let r: { status: number; body: string };
        try {
          r = await post("/v1/keeper/alerts", { instance: target.instance, alerts: lines });
        } catch (err) {
          return fail("alerts", err);
        }
        if (r.status === 422) {
          let refused: unknown = r.body;
          try {
            refused = (JSON.parse(r.body) as { refused?: unknown }).refused;
          } catch {}
          deps.log({ type: "keeper.monitorSink", event: "refused", instance: target.instance, refused });
        } else if (r.status !== 200) {
          return fail("alerts", `HTTP ${r.status}: ${r.body.slice(0, 200)}`);
        }
        queue.splice(0, lines.length);
      } else {
        const block = beat!;
        let r: { status: number; body: string };
        try {
          r = await post("/v1/keeper/heartbeat", { instance: target.instance, blockNumber: block.toString(10) });
        } catch (err) {
          return fail("heartbeat", err);
        }
        if (r.status !== 200) return fail("heartbeat", `HTTP ${r.status}: ${r.body.slice(0, 200)}`);
        if (beat === block) beat = null;
      }
      if (failing) deps.log({ type: "keeper.monitorSink", event: "recovered", instance: target.instance });
      failing = false;
    }
  }

  const kick = () => {
    if (running) return running;
    running = drain().finally(() => {
      running = null;
    });
    return running;
  };

  return {
    async send(alert: Alert) {
      queue.push({ signal: alert.signal, level: alert.level, chainId: alert.chainId, blockNumber: alert.blockNumber.toString(10), subject: alert.subject, detail: alert.detail });
      if (queue.length > maxQueue) {
        const dropped = queue.splice(0, queue.length - maxQueue);
        deps.log({ type: "keeper.monitorSink", event: "dropped", instance: target.instance, lines: dropped.length });
      }
      void kick();
    },
    heartbeat(blockNumber: bigint) {
      if (beat === null || blockNumber > beat) beat = blockNumber;
      void kick();
    },
    flush: () => kick(),
  };
}

/** Every alert to each sink: the log line stays the record the failure log is published from. */
export function teeSink(...sinks: readonly AlertSink[]): AlertSink {
  return {
    async send(alert: Alert) {
      await Promise.all(sinks.map((s) => s.send(alert)));
    },
  };
}
