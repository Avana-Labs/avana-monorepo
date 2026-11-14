// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The PagerDuty and webhook payloads, retries and per-channel failure, and the second-provider confirmation of pages.

import { describe, expect, it } from "vitest";
import { FIXTURE_HUB, fixtureHubAsset, fixtureMarkets, fixtureSlices, fixtureSpokeReserves } from "@avana/services-common/fixtures";
import type { ChainSnapshot } from "@avana/services-common/views";
import { confirmPages, rowsFor } from "../src/confirm.ts";
import { type Channel, type FetchLike, dedupKey, deliver, logChannel, pagerDutyChannel, summary, webhookChannel } from "../src/notify/channels.ts";
import type { Finding, Notice } from "../src/types.ts";

const notice = (transition: Notice["transition"] = "open", level: "warn" | "page" = "page"): Notice => ({
  alert: { signal: "M-15", level, chainId: 1, blockNumber: 21_000_000n, subject: `hubAsset:${FIXTURE_HUB}:1`, detail: { deficit: "5000000" } },
  transition,
  timestamp: 1_700_000_000,
});

function recorder(status = 202) {
  const calls: { url: string; body: Record<string, unknown> }[] = [];
  const fetchFn: FetchLike = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
    return { ok: status < 300, status, text: async () => "body" };
  };
  return { calls, fetchFn };
}

const instant = { attempts: 3, backoffMs: 1, sleep: async () => {} };

describe("PagerDuty", () => {
  it("triggers a critical incident for a page, keyed by chain, signal and subject", async () => {
    const { calls, fetchFn } = recorder();
    await pagerDutyChannel("pd", "rk", fetchFn).send(notice());
    expect(calls[0]!.url).toBe("https://events.pagerduty.com/v2/enqueue");
    expect(calls[0]!.body).toMatchObject({
      routing_key: "rk",
      event_action: "trigger",
      dedup_key: `avana|1|M-15|hubAsset:${FIXTURE_HUB}:1`,
      payload: { severity: "critical", group: "M-15", custom_details: { deficit: "5000000", block: "21000000", playbook: "P-09 (EMG-083)", responders: "coverageRole" } },
    });
  });

  it("resolves the same incident and gives each event its own key", async () => {
    const { calls, fetchFn } = recorder();
    await pagerDutyChannel("pd", "rk", fetchFn).send(notice("resolve"));
    expect(calls[0]!.body).toEqual({ routing_key: "rk", event_action: "resolve", dedup_key: `avana|1|M-15|hubAsset:${FIXTURE_HUB}:1` });
    expect(dedupKey(notice("event"))).toBe(`avana|1|M-15|hubAsset:${FIXTURE_HUB}:1|21000000`);
  });

  it("sends a warn as a warning", async () => {
    const { calls, fetchFn } = recorder();
    await pagerDutyChannel("pd", "rk", fetchFn).send(notice("open", "warn"));
    expect((calls[0]!.body.payload as { severity: string }).severity).toBe("warning");
  });
});

describe("webhook and log", () => {
  it("posts the summary as text with the notice, block as a decimal string", async () => {
    const { calls, fetchFn } = recorder(200);
    await webhookChannel("slack", "https://hooks.example/x", fetchFn).send(notice());
    expect(calls[0]!.body.text).toBe(`[PAGE] M-15 Hub deficit per asset: hubAsset:${FIXTURE_HUB}:1 on chain 1 at block 21000000 (open). Playbook P-09 (EMG-083). deficit=5000000`);
    expect((calls[0]!.body.notice as { alert: { blockNumber: string } }).alert.blockNumber).toBe("21000000");
  });

  it("marks a resolution and caps the summary at 1,024 characters", () => {
    expect(summary(notice("resolve"))).toMatch(/^\[RESOLVED\] M-15/);
    const long = notice();
    expect(summary({ ...long, alert: { ...long.alert, detail: { x: "y".repeat(2_000) } } })).toHaveLength(1_024);
  });

  it("writes a log line", async () => {
    const lines: string[] = [];
    await logChannel("log", (l) => lines.push(l)).send(notice());
    expect(JSON.parse(lines[0]!)).toMatchObject({ type: "monitor.alert", signal: "M-15", blockNumber: "21000000" });
  });
});

describe("deliver", () => {
  it("retries a failing channel and reports each channel's answer without stopping the others", async () => {
    let tries = 0;
    const flaky: Channel = { name: "flaky", send: async () => { if (++tries < 3) throw new Error("timeout"); } };
    const down: Channel = { name: "down", send: async () => { throw new Error("HTTP 503"); } };
    const fine: Channel = { name: "fine", send: async () => {} };
    expect(await deliver(notice(), [flaky, down, fine], instant)).toEqual([
      { channel: "flaky", ok: true },
      { channel: "down", ok: false, error: "HTTP 503" },
      { channel: "fine", ok: true },
    ]);
    expect(tries).toBe(3);
  });

  it("reports an HTTP error status as a failure", async () => {
    const { fetchFn } = recorder(500);
    expect(await deliver(notice(), [pagerDutyChannel("pd", "rk", fetchFn)], instant)).toEqual([{ channel: "pd", ok: false, error: "HTTP 500: body" }]);
  });
});

describe("second-provider confirmation", () => {
  const snap = (block: string, edit: (s: ChainSnapshot) => ChainSnapshot = (s) => s): ChainSnapshot =>
    edit({ chainId: 1, blockNumber: block, timestamp: 0, hubs: [], creditLines: [], hubAssets: [fixtureHubAsset], slices: fixtureSlices, spokeReserves: fixtureSpokeReserves, markets: fixtureMarkets });
  const page: Finding = { signal: "M-01", kind: "condition", level: "page", subject: "market:1", detail: {} };
  const warn: Finding = { ...page, level: "warn", subject: "market:2" };

  it("keeps a page whose rows match and does not read the second provider without a page", async () => {
    expect(await confirmPages([page, warn], snap("5"), async () => snap("5"))).toEqual([page, warn]);
    let read = false;
    await confirmPages([warn], snap("5"), async () => { read = true; return snap("5"); });
    expect(read).toBe(false);
  });

  it("turns a page the second provider reads differently into a warn", async () => {
    const other = snap("5", (s) => ({ ...s, markets: s.markets.map((m) => (m.marketId === "1" ? { ...m, priceState: 3 } : m)) }));
    const [f] = await confirmPages([page], snap("5"), async () => other);
    expect(f).toMatchObject({ level: "warn", detail: { note: "not confirmed on the second provider" } });
  });

  it("refuses a second read at another block, and pages unconfirmed when the second provider is down", async () => {
    expect((await confirmPages([page], snap("5"), async () => snap("6")))[0]).toMatchObject({ level: "page", detail: { note: "unconfirmed, second provider unavailable: second provider read block 6, not 5" } });
    expect((await confirmPages([page], snap("5"), async () => { throw new Error("ECONNREFUSED"); }))[0]!.detail.note).toMatch(/ECONNREFUSED/);
  });

  it("finds the rows of every subject kind", () => {
    const s = snap("5");
    expect(rowsFor(s, "market:1")).not.toBeNull();
    expect(rowsFor(s, `hubAsset:${FIXTURE_HUB}:1`)).not.toBeNull();
    expect(rowsFor(s, `reserve:${fixtureSpokeReserves[0]!.spoke}:1`)).not.toBeNull();
    expect(rowsFor(s, `slice:${FIXTURE_HUB}:1:${fixtureSlices[0]!.spoke}:withdrawals`)).not.toBeNull();
    expect(rowsFor(s, "market:99")).toBeNull();
    expect(rowsFor(s, "account:0x1")).toBeNull();
  });
});
