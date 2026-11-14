// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The keeper's side of monitoring: alert lines and heartbeats posted to the monitor (batching, bearer token, retry on
// failure, refused lines dropped, the queue bound), M-16 and M-17 levels and their reads with the page confirmed on the
// second provider, the measured daily gas spend, and M-10 counted per market per hour.

import { describe, expect, it } from "vitest";
import type { Address, PublicClient } from "viem";
import { monitorSink, teeSink } from "../src/adapters/monitorSink.ts";
import type { Alert } from "../src/monitoring/alerts.ts";
import { SpendTracker, fundingCheck, m16Level, m17GasLevel, m17IdleLevel, parseLargest } from "../src/monitoring/funding.ts";
import { RevertWindow, m10Level } from "../src/monitoring/m10.ts";

const alert = (n: number): Alert => ({ signal: "M-10", level: "warn", chainId: 1, blockNumber: BigInt(n), subject: `market:${n}`, detail: { reason: "X" } });

function fakeMonitor(answer: (path: string, body: any) => number) {
  const calls: { path: string; body: any; auth: string | null }[] = [];
  const fetch = (async (url: string, init: RequestInit) => {
    const path = new URL(url).pathname;
    const body = JSON.parse(String(init.body));
    calls.push({ path, body, auth: new Headers(init.headers).get("authorization") });
    const status = answer(path, body);
    const refused = status === 422 ? [{ index: 0, reason: "unknown signal" }] : [];
    return new Response(JSON.stringify({ refused }), { status });
  }) as unknown as typeof globalThis.fetch;
  return { calls, fetch };
}

describe("monitor sink", () => {
  const target = { url: "http://monitor:9470/", instance: "eth-primary", token: "t0k" };

  it("posts alert lines and the latest heartbeat with the instance and its bearer token", async () => {
    const m = fakeMonitor(() => 200);
    const sink = monitorSink(target, { fetch: m.fetch, log: () => {} });
    await sink.send(alert(1));
    sink.heartbeat(5n);
    sink.heartbeat(7n);
    sink.heartbeat(6n);
    await sink.flush();
    await sink.flush();
    expect(m.calls.every((c) => c.auth === "Bearer t0k")).toBe(true);
    const alerts = m.calls.filter((c) => c.path === "/v1/keeper/alerts");
    expect(alerts[0]!.body).toEqual({ instance: "eth-primary", alerts: [{ signal: "M-10", level: "warn", chainId: 1, blockNumber: "1", subject: "market:1", detail: { reason: "X" } }] });
    const beats = m.calls.filter((c) => c.path === "/v1/keeper/heartbeat").map((c) => c.body.blockNumber);
    expect(beats.at(-1)).toBe("7");
    expect(beats).not.toContain("6");
  });

  it("keeps lines through an outage, logs it once, and sends them when the monitor answers again", async () => {
    let up = false;
    const logs: Record<string, unknown>[] = [];
    const m = fakeMonitor(() => (up ? 200 : 503));
    const sink = monitorSink(target, { fetch: m.fetch, log: (r) => logs.push(r) });
    await sink.send(alert(1));
    await sink.flush();
    await sink.send(alert(2));
    await sink.flush();
    expect(logs.map((l) => l.event)).toEqual(["failed"]);
    up = true;
    sink.heartbeat(3n);
    await sink.flush();
    const sent = m.calls.filter((c) => c.path === "/v1/keeper/alerts").at(-1)!.body.alerts.map((a: any) => a.blockNumber);
    expect(sent).toEqual(["1", "2"]);
    expect(logs.map((l) => l.event)).toEqual(["failed", "recovered"]);
  });

  it("drops lines the monitor refuses instead of retrying them", async () => {
    const logs: Record<string, unknown>[] = [];
    const m = fakeMonitor((path) => (path === "/v1/keeper/alerts" ? 422 : 200));
    const sink = monitorSink(target, { fetch: m.fetch, log: (r) => logs.push(r) });
    await sink.send(alert(1));
    await sink.flush();
    await sink.send(alert(2));
    await sink.flush();
    expect(m.calls.filter((c) => c.path === "/v1/keeper/alerts").map((c) => c.body.alerts.length)).toEqual([1, 1]);
    expect(logs.filter((l) => l.event === "refused")).toHaveLength(2);
  });

  it("bounds the queue, dropping the oldest lines", async () => {
    const logs: Record<string, unknown>[] = [];
    let up = false;
    const m = fakeMonitor(() => (up ? 200 : 503));
    const sink = monitorSink(target, { fetch: m.fetch, log: (r) => logs.push(r), maxQueue: 2 });
    for (let i = 1; i <= 4; i++) await sink.send(alert(i));
    await sink.flush();
    expect(logs.some((l) => l.event === "dropped")).toBe(true);
    up = true;
    sink.heartbeat(5n);
    await sink.flush();
    expect(m.calls.filter((c) => c.path === "/v1/keeper/alerts").at(-1)!.body.alerts.map((a: any) => a.blockNumber)).toEqual(["3", "4"]);
  });

  it("tees every alert to each sink", async () => {
    const seen: string[] = [];
    const tee = teeSink({ send: async (a) => void seen.push(`a:${a.subject}`) }, { send: async (a) => void seen.push(`b:${a.subject}`) });
    await tee.send(alert(1));
    expect(seen).toEqual(["a:market:1", "b:market:1"]);
  });
});

describe("M-16 and M-17 levels", () => {
  it("float: 150 % warns, 100 % pages", () => {
    expect([m16Level(150n, 100n), m16Level(149n, 100n), m16Level(100n, 100n), m16Level(99n, 100n)]).toEqual(["ok", "warn", "warn", "page"]);
  });

  it("idle liquidity: 2x warns, 1x pages", () => {
    expect([m17IdleLevel(200n, 100n), m17IdleLevel(199n, 100n), m17IdleLevel(99n, 100n)]).toEqual(["ok", "warn", "page"]);
  });

  it("gas: 3 days warn, 1 day pages, nothing without a spend", () => {
    expect([m17GasLevel(300n, 100n), m17GasLevel(299n, 100n), m17GasLevel(99n, 100n), m17GasLevel(0n, 0n)]).toEqual(["ok", "warn", "page", "ok"]);
  });

  it("parses the largest debtToCover per asset and refuses a malformed or repeated entry", () => {
    const usdc = "0x00000000000000000000000000000000000000AA";
    expect(parseLargest([`${usdc}:2000000000000`], "X")).toEqual(new Map([[usdc.toLowerCase(), 2_000_000_000_000n]]));
    expect(() => parseLargest([`${usdc}:0`], "X")).toThrow(/positive amount/);
    expect(() => parseLargest(["usdc:1"], "X")).toThrow(/asset:amount/);
    expect(() => parseLargest([`${usdc}:1`, `${usdc.toLowerCase()}:2`], "X")).toThrow(/twice/);
  });
});

describe("measured daily gas spend", () => {
  const DAY = 86_400n;

  it("counts balance decreases per day, not top-ups, and takes the median of the complete days", () => {
    const t = new SpendTracker();
    const start = 100n * DAY + 10n;
    t.observe(1_000n, start); // day 100, partly watched: not counted
    t.observe(990n, start + 10n);
    expect(t.median(start + 20n)).toBeNull();
    // Days 101 to 103 spend 30, 10 and 20; a top-up on day 102 is not spend.
    t.observe(960n, 101n * DAY + 5n);
    t.observe(5_000n, 102n * DAY + 5n);
    t.observe(4_990n, 102n * DAY + 6n);
    t.observe(4_970n, 103n * DAY + 6n);
    expect(t.median(104n * DAY)).toBe(20n);
    // A watched day without spend counts as 0.
    expect(t.median(106n * DAY)).toBe(10n);
  });
});

describe("funding check", () => {
  const ASSET = "0x00000000000000000000000000000000000000aa" as Address;
  const SAFE = "0x00000000000000000000000000000000000000bb" as Address;
  const HELPER = "0x00000000000000000000000000000000000000cc" as Address;
  const SIGNER = "0x00000000000000000000000000000000000000dd" as Address;

  const client = (v: { balance: bigint; idle: bigint; gas: bigint }) =>
    ({
      readContract: async (args: { functionName: string; blockNumber: bigint }) => {
        expect(args.blockNumber).toBe(50n);
        return args.functionName === "balanceOf" ? v.balance : v.idle;
      },
      getBalance: async () => v.gas,
    }) as unknown as PublicClient;

  async function run(primary: { balance: bigint; idle: bigint; gas: bigint }, fallback = primary, largest = new Map([[ASSET, 1_000n]])) {
    const sent: Alert[] = [];
    const check = fundingCheck({
      chainId: 1,
      primary: client(primary),
      fallback: client(fallback),
      alerts: { send: async (a) => void sent.push(a) },
      assets: [ASSET],
      fundingSafe: SAFE,
      helper: HELPER,
      largest,
      free: (_asset, safeBalance) => safeBalance - 100n, // 100 reserved
      gas: { signer: SIGNER, dailyFloorWei: 10n, spend: new SpendTracker() },
    });
    await check({ number: 50n, timestamp: 1_000n });
    return sent.map((a) => `${a.signal}:${a.subject}:${a.level}`);
  }

  it("judges the float after reservations, the Pool's idle liquidity and the signer's gas", async () => {
    expect(await run({ balance: 1_600n, idle: 2_000n, gas: 30n })).toEqual([]);
    expect(await run({ balance: 1_500n, idle: 1_999n, gas: 29n })).toEqual([`M-16:float:${ASSET}:warn`, `M-17:idle:${ASSET}:warn`, `M-17:gas:${SIGNER}:warn`]);
    expect(await run({ balance: 1_000n, idle: 999n, gas: 9n })).toEqual([`M-16:float:${ASSET}:page`, `M-17:idle:${ASSET}:page`, `M-17:gas:${SIGNER}:page`]);
  });

  it("sends a page the second provider does not confirm as a warn", async () => {
    expect(await run({ balance: 1_000n, idle: 999n, gas: 9n }, { balance: 5_000n, idle: 5_000n, gas: 500n })).toEqual([`M-16:float:${ASSET}:warn`, `M-17:idle:${ASSET}:warn`, `M-17:gas:${SIGNER}:warn`]);
  });

  it("warns on a debt asset without a configured largest debtToCover", async () => {
    expect(await run({ balance: 10n ** 30n, idle: 10n ** 30n, gas: 10n ** 30n }, undefined, new Map())).toEqual([`M-16:float:${ASSET}:warn`]);
  });
});

describe("M-10 per market", () => {
  it("counts each account once per hour per market: 1 warns, 3 page, and a page stays a page", () => {
    const w = new RevertWindow(300n);
    expect(m10Level(w.record("7", "0xA", 1n), "warn")).toBe("warn");
    expect(m10Level(w.record("7", "0xa", 2n), "warn")).toBe("warn"); // same account again
    expect(m10Level(w.record("7", "0xB", 3n), "warn")).toBe("warn");
    expect(m10Level(w.record("8", "0xC", 3n), "warn")).toBe("warn"); // another market
    expect(m10Level(w.record("7", "0xC", 4n), "warn")).toBe("page");
    expect(w.record("7", "0xD", 303n)).toBe(2); // 0xA (block 2) and 0xB (block 3) left the window
    expect(m10Level(1, "page")).toBe("page");
  });
});
