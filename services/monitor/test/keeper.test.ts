// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Keeper alerts held while they keep arriving and resolved after the grace, the 3-block silence page, the checks on
// each posted line, and the ingest endpoint's authentication.

import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { AlertBook } from "../src/alertBook.ts";
import { KeeperFeed, type KeeperAlertLine, refusal } from "../src/keeper.ts";
import { monitorServer } from "../src/server.ts";

const primary = { name: "eth-primary", chainId: 1 };
const standby = { name: "eth-standby", chainId: 1 };
const line = (block: number, level = "warn", signal = "M-09", subject = "0xproxy"): KeeperAlertLine => ({ signal, level, chainId: 1, blockNumber: String(block), subject, detail: { since: "90" } });
const levels = (feed: KeeperFeed, head: bigint) => Object.fromEntries(feed.findings(1, head).map((f) => [f.subject, f.level]));

describe("KeeperFeed", () => {
  it("holds an alert while it keeps arriving and resolves it after the grace", () => {
    const feed = new KeeperFeed([primary]);
    feed.alert(primary, line(100));
    expect(levels(feed, 102n)["keeper:0xproxy"]).toBe("warn");
    expect(levels(feed, 103n)["keeper:0xproxy"]).toBe("ok");
    expect(levels(feed, 104n)["keeper:0xproxy"]).toBeUndefined();
  });

  it("merges two instances' reports of one subject, the page winning within a block", () => {
    const feed = new KeeperFeed([primary, standby]);
    feed.alert(primary, line(100, "page"));
    feed.alert(standby, line(100, "warn"));
    feed.alert(standby, line(99, "warn"));
    const f = feed.findings(1, 100n).filter((x) => x.subject === "keeper:0xproxy");
    expect(f).toHaveLength(1);
    expect(f[0]).toMatchObject({ level: "page", detail: { instance: "eth-primary", lastReportedBlock: "100" } });
  });

  it("pages an instance 3 blocks behind the head, counting a never-heard instance from the monitor's start", () => {
    const feed = new KeeperFeed([primary, standby]);
    feed.heartbeat(primary, 100n);
    expect(levels(feed, 102n)).toMatchObject({ "keeperInstance:eth-primary": "ok", "keeperInstance:eth-standby": "ok" });
    expect(levels(feed, 103n)).toMatchObject({ "keeperInstance:eth-primary": "page", "keeperInstance:eth-standby": "ok" });
    expect(levels(feed, 105n)).toMatchObject({ "keeperInstance:eth-standby": "page" });
    feed.heartbeat(primary, 104n);
    feed.heartbeat(primary, 90n); // never moves backwards
    expect(levels(feed, 105n)["keeperInstance:eth-primary"]).toBe("ok");
  });

  it("feeds the alert book: one notice per open and one resolution", () => {
    const feed = new KeeperFeed([primary]);
    const book = new AlertBook();
    const tick = (head: bigint) => book.apply({ source: "keeper", chainId: 1, blockNumber: head, timestamp: 0, findings: feed.findings(1, head), complete: true });
    feed.heartbeat(primary, 100n);
    feed.alert(primary, line(100));
    expect(tick(100n).map((n) => n.transition)).toEqual(["open"]);
    feed.alert(primary, line(101));
    expect(tick(101n)).toEqual([]);
    feed.heartbeat(primary, 104n);
    expect(tick(104n).map((n) => `${n.transition}:${n.alert.subject}`)).toEqual(["resolve:keeper:0xproxy"]);
  });

  it("refuses unknown signals, levels, another chain, a bad block and long fields", () => {
    expect(refusal(primary, line(1))).toBeNull();
    expect(refusal(primary, line(1, "warn", "M-99"))).toMatch(/unknown signal/);
    expect(refusal(primary, line(1, "ok"))).toMatch(/not warn or page/);
    expect(refusal(primary, { ...line(1), chainId: 8453 })).toMatch(/chain/);
    expect(refusal(primary, { ...line(1), blockNumber: "-1" })).toMatch(/decimal/);
    expect(refusal(primary, line(1, "warn", "M-09", "x".repeat(201)))).toMatch(/subject/);
    expect(refusal(primary, { ...line(1), detail: { k: "v".repeat(1_001) } })).toMatch(/detail k/);
  });
});

describe("ingest endpoint", () => {
  let close: (() => void) | null = null;
  afterEach(() => close?.());

  async function start() {
    const feed = new KeeperFeed([primary]);
    const server = monitorServer({ keeperTokens: new Map([["eth-primary", "secret-1"]]), statusToken: "status-1" }, feed, () => [{ signal: "M-01", level: "warn", chainId: 1, blockNumber: 5n, subject: "market:1", detail: {} }]);
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    close = () => server.close();
    const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    const post = (path: string, token: string, body: unknown) => fetch(`${base}${path}`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body) });
    return { feed, base, post };
  }

  it("accepts an instance's alerts and heartbeat with its token", async () => {
    const { feed, post } = await start();
    const r = await post("/v1/keeper/alerts", "secret-1", { instance: "eth-primary", alerts: [line(100), line(100, "page", "M-26", "LPVaultSwap")] });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ accepted: 2, refused: [] });
    expect((await post("/v1/keeper/heartbeat", "secret-1", { instance: "eth-primary", blockNumber: "101" })).status).toBe(200);
    expect(levels(feed, 101n)).toMatchObject({ "keeper:0xproxy": "warn", "keeper:LPVaultSwap": "page", "keeperInstance:eth-primary": "ok" });
  });

  it("answers 401 alike for a wrong token and an unknown instance", async () => {
    const { post } = await start();
    expect((await post("/v1/keeper/alerts", "wrong", { instance: "eth-primary", alerts: [] })).status).toBe(401);
    expect((await post("/v1/keeper/alerts", "secret-1", { instance: "base-primary", alerts: [] })).status).toBe(401);
  });

  it("reports refused lines with 422 and keeps the good ones", async () => {
    const { feed, post } = await start();
    const r = await post("/v1/keeper/alerts", "secret-1", { instance: "eth-primary", alerts: [line(100), line(100, "warn", "M-77")] });
    expect(r.status).toBe(422);
    expect(await r.json()).toEqual({ accepted: 1, refused: [{ index: 1, reason: "unknown signal M-77" }] });
    expect(levels(feed, 100n)["keeper:0xproxy"]).toBe("warn");
  });

  it("refuses a malformed body, a bad heartbeat and an unknown path", async () => {
    const { base, post } = await start();
    expect((await fetch(`${base}/v1/keeper/alerts`, { method: "POST", headers: { authorization: "Bearer secret-1" }, body: "{" })).status).toBe(400);
    expect((await post("/v1/keeper/heartbeat", "secret-1", { instance: "eth-primary", blockNumber: 7 })).status).toBe(400);
    expect((await post("/v1/other", "secret-1", {})).status).toBe(404);
  });

  it("serves open alerts with the status token only", async () => {
    const { base } = await start();
    expect((await fetch(`${base}/v1/status`)).status).toBe(401);
    const r = await fetch(`${base}/v1/status`, { headers: { authorization: "Bearer status-1" } });
    expect(await r.json()).toEqual({ open: [{ signal: "M-01", level: "warn", chainId: 1, blockNumber: "5", subject: "market:1", detail: {} }] });
    expect((await fetch(`${base}/healthz`)).status).toBe(200);
  });

  it("refuses to start without a token for every instance", () => {
    expect(() => monitorServer({ keeperTokens: new Map(), statusToken: "s" }, new KeeperFeed([primary]), () => [])).toThrow(/no token for keeper instance eth-primary/);
  });
});
