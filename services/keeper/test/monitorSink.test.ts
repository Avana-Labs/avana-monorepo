// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The alert lines and heartbeats posted to the monitor: batched with the instance's bearer token, kept and retried
// after a failure, a refused (422) line dropped, and the queue bounded.

import { describe, expect, it } from "vitest";
import type { Alert } from "../src/alerts.ts";
import { monitorSink, teeSink } from "../src/monitorSink.ts";

const alert = (n: number): Alert => ({ signal: "M-10", level: "warn", chainId: 1, blockNumber: BigInt(n), subject: `market:${n}`, detail: { reason: "X" } });

function fakeMonitor(answer: (path: string) => number) {
  const calls: { path: string; body: any; auth: string | null }[] = [];
  const fetch = (async (url: string, init: RequestInit) => {
    const path = new URL(url).pathname;
    calls.push({ path, body: JSON.parse(String(init.body)), auth: new Headers(init.headers).get("authorization") });
    return new Response(JSON.stringify({ refused: [] }), { status: answer(path) });
  }) as unknown as typeof globalThis.fetch;
  return { calls, fetch };
}

describe("monitor sink", () => {
  const target = { url: "http://monitor:9470/", instance: "base-primary", token: "t0k" };

  it("posts alerts and the heartbeat with the bearer token", async () => {
    const m = fakeMonitor(() => 200);
    const sink = monitorSink(target, { fetch: m.fetch, log: () => {} });
    await sink.send(alert(1));
    sink.heartbeat(7n);
    await sink.flush();
    expect(m.calls.map((c) => [c.path, c.auth])).toEqual([
      ["/v1/keeper/alerts", "Bearer t0k"],
      ["/v1/keeper/heartbeat", "Bearer t0k"],
    ]);
    expect(m.calls[0]!.body.alerts[0]).toMatchObject({ signal: "M-10", blockNumber: "1" });
    expect(m.calls[1]!.body).toEqual({ instance: "base-primary", blockNumber: "7" });
  });

  it("keeps lines through an outage and drops the oldest beyond the bound", async () => {
    let up = false;
    const logs: Record<string, unknown>[] = [];
    const m = fakeMonitor(() => (up ? 200 : 503));
    const sink = monitorSink(target, { fetch: m.fetch, log: (r) => void logs.push(r), maxQueue: 2 });
    for (const n of [1, 2, 3]) await sink.send(alert(n));
    await sink.flush();
    up = true;
    await sink.send(alert(4));
    await sink.flush();
    const delivered = m.calls.filter((c, i) => c.path === "/v1/keeper/alerts" && i > 0).flatMap((c) => c.body.alerts.map((a: { subject: string }) => a.subject));
    expect(delivered).toContain("market:4");
    expect(delivered).not.toContain("market:1");
    expect(logs.map((l) => l.event)).toContain("dropped");
  });

  it("tees every alert to each sink", async () => {
    const got: string[] = [];
    await teeSink({ send: async (a) => void got.push(`a:${a.subject}`) }, { send: async (a) => void got.push(`b:${a.subject}`) }).send(alert(5));
    expect(got).toEqual(["a:market:5", "b:market:5"]);
  });
});
