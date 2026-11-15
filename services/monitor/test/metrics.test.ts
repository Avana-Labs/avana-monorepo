// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The monitor's metrics: the text exposition of open alerts, rounds, probe failures, keeper heartbeats and deliveries,
// the incident log that counts what it writes, the /metrics endpoint's token, and the token's configuration checks.

import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import type { IncidentEntry } from "../src/incidentLog.ts";
import { KeeperFeed } from "../src/keeper.ts";
import { MonitorMetrics } from "../src/metrics.ts";
import { monitorServer } from "../src/server.ts";
import { SIGNALS } from "../src/signals.ts";
import type { Alert } from "../src/types.ts";

const chains = [
  { id: 1, key: "mainnet", probes: ["snapshot", "oracle"] },
  { id: 8453, key: "base", probes: ["snapshot"] },
];
const keepers = [
  { name: "eth-primary", chainId: 1 },
  { name: "eth-standby", chainId: 1 },
  { name: "base-primary", chainId: 8453 },
];
const alert = (signal: Alert["signal"], level: Alert["level"], chainId = 1, subject = "market:1"): Alert => ({ signal, level, chainId, blockNumber: 5n, subject, detail: {} });
const entry = (deliveries: IncidentEntry["deliveries"]): IncidentEntry => ({
  type: "monitor.notice",
  transition: "open",
  signal: "M-07",
  level: "page",
  chainId: 1,
  blockNumber: "5",
  timestamp: 0,
  subject: "market:1:poolShare",
  detail: {},
  recipients: ["onCall"],
  deliveries,
});

/** The value of one series, or undefined when the text has no such line. */
function value(text: string, series: string): string | undefined {
  const line = text.split("\n").find((l) => l.startsWith(`${series} `));
  return line?.slice(series.length + 1);
}

describe("MonitorMetrics", () => {
  it("counts open alerts per chain, signal and level, with a zero for every other signal", () => {
    const m = new MonitorMetrics(chains, keepers, ["pd"], 1_000);
    const text = m.render([alert("M-07", "page"), alert("M-07", "page", 1, "market:2"), alert("M-01", "warn", 8453)], () => undefined);
    expect(value(text, 'monitor_open_alerts{chain="mainnet",signal="M-07",level="page"}')).toBe("2");
    expect(value(text, 'monitor_open_alerts{chain="base",signal="M-01",level="warn"}')).toBe("1");
    expect(value(text, 'monitor_open_alerts{chain="mainnet",signal="M-01",level="warn"}')).toBe("0");
    expect(text.split("\n").filter((l) => l.startsWith("monitor_open_alerts{"))).toHaveLength(chains.length * SIGNALS.length * 2);
    expect(value(text, "monitor_start_time_seconds")).toBe("1000");
    expect(text).toContain("# TYPE monitor_open_alerts gauge");
  });

  it("records rounds, their duration, the last success and each failed probe", () => {
    const m = new MonitorMetrics(chains, keepers, [], 0);
    let text = m.render([], () => undefined);
    expect(value(text, 'monitor_rounds_total{chain="mainnet",result="failed"}')).toBe("0");
    expect(value(text, 'monitor_probe_read_failures_total{chain="mainnet",probe="oracle"}')).toBe("0");
    expect(value(text, 'monitor_round_last_success_timestamp_seconds{chain="mainnet"}')).toBeUndefined();

    m.round(1, { ok: true, durationSeconds: 1.5, endedAt: 100, failedProbes: [] });
    m.round(1, { ok: false, durationSeconds: 2.25, endedAt: 112, failedProbes: ["oracle"] });
    m.round(1, { ok: false, durationSeconds: 0.5, endedAt: 124, failedProbes: [] });
    text = m.render([], () => undefined);
    expect(value(text, 'monitor_rounds_total{chain="mainnet",result="ok"}')).toBe("1");
    expect(value(text, 'monitor_rounds_total{chain="mainnet",result="failed"}')).toBe("2");
    expect(value(text, 'monitor_round_duration_seconds{chain="mainnet"}')).toBe("0.5");
    expect(value(text, 'monitor_round_last_success_timestamp_seconds{chain="mainnet"}')).toBe("100");
    expect(value(text, 'monitor_probe_read_failures_total{chain="mainnet",probe="oracle"}')).toBe("1");
    expect(value(text, 'monitor_probe_read_failures_total{chain="mainnet",probe="snapshot"}')).toBe("0");
    expect(value(text, 'monitor_rounds_total{chain="base",result="ok"}')).toBe("0");
  });

  it("reports each keeper instance's heartbeat and its age behind the chain's head, and nothing for one never heard", () => {
    const m = new MonitorMetrics(chains, keepers, [], 0);
    const feed = new KeeperFeed(keepers);
    feed.heartbeat(keepers[0]!, 100n);
    feed.heartbeat(keepers[2]!, 50n);
    m.head(1, 104n);
    const text = m.render([], (name) => feed.lastHeartbeat(name));
    expect(value(text, 'monitor_keeper_heartbeat_block{keeper="eth-primary",chain="mainnet"}')).toBe("100");
    expect(value(text, 'monitor_keeper_heartbeat_age_blocks{keeper="eth-primary",chain="mainnet"}')).toBe("4");
    expect(value(text, 'monitor_head_block{chain="mainnet"}')).toBe("104");
    // Base has no head read yet: the heartbeat is reported, its age is not.
    expect(value(text, 'monitor_keeper_heartbeat_block{keeper="base-primary",chain="base"}')).toBe("50");
    expect(value(text, 'monitor_keeper_heartbeat_age_blocks{keeper="base-primary",chain="base"}')).toBeUndefined();
    expect(text).not.toContain('keeper="eth-standby"');
  });

  it("counts each notice and each channel's answer as the incident log writes them", () => {
    const m = new MonitorMetrics(chains, keepers, ["pd", "ops"], 0);
    const written: IncidentEntry[] = [];
    const log = m.countingLog({ write: (e) => written.push(e) });
    log.write(entry([{ channel: "pd", ok: true }, { channel: "ops", ok: false, error: "HTTP 500" }]));
    log.write(entry([{ channel: "pd", ok: true }]));
    expect(written).toHaveLength(2);
    const text = m.render([], () => undefined);
    expect(value(text, 'monitor_notices_total{chain="mainnet",signal="M-07",level="page",transition="open"}')).toBe("2");
    expect(value(text, 'monitor_deliveries_total{channel="pd",result="ok"}')).toBe("2");
    expect(value(text, 'monitor_deliveries_total{channel="ops",result="failed"}')).toBe("1");
    expect(value(text, 'monitor_deliveries_total{channel="ops",result="ok"}')).toBe("0");
  });

  it("escapes label values", () => {
    const m = new MonitorMetrics(chains, [], ['a"b\\c\nd'], 0);
    expect(m.render([], () => undefined)).toContain('monitor_deliveries_total{channel="a\\"b\\\\c\\nd",result="ok"} 0');
  });
});

describe("GET /metrics", () => {
  let close: (() => void) | null = null;
  afterEach(() => close?.());

  async function start(metricsToken: string | null) {
    const feed = new KeeperFeed([keepers[0]!]);
    const m = new MonitorMetrics(chains, [keepers[0]!], [], 0);
    const server = monitorServer({ keeperTokens: new Map([["eth-primary", "k"]]), statusToken: "status-1", metricsToken }, feed, () => [alert("M-01", "warn")], undefined, undefined, () =>
      m.render([alert("M-01", "warn")], (name) => feed.lastHeartbeat(name)),
    );
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    close = () => server.close();
    const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    return (token?: string) => fetch(`${base}/metrics`, token ? { headers: { authorization: `Bearer ${token}` } } : {});
  }

  it("serves the text format with the metrics token only", async () => {
    const get = await start("metrics-1");
    expect((await get()).status).toBe(401);
    expect((await get("status-1")).status).toBe(401);
    const r = await get("metrics-1");
    expect(r.status).toBe(200);
    expect(r.headers.get("content-type")).toMatch(/^text\/plain; version=0\.0\.4/);
    expect(value(await r.text(), 'monitor_open_alerts{chain="mainnet",signal="M-01",level="warn"}')).toBe("1");
  });

  it("answers 404 when no metrics token is configured", async () => {
    const get = await start(null);
    expect((await get("anything")).status).toBe(404);
  });
});
