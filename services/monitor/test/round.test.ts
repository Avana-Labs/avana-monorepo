// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One round end to end on a scripted chain (probes, second-provider confirmation, keeper findings, routing, delivery
// and the incident log), a failing probe, and the configuration's refusals.

import { describe, expect, it } from "vitest";
import type { ServiceManifest } from "@avana/services-common";
import { AlertBook } from "../src/alertBook.ts";
import { loadConfig, routeEnvName } from "../src/config.ts";
import { snapshotProbe } from "../src/confirm.ts";
import type { IncidentEntry } from "../src/incidentLog.ts";
import { KeeperFeed } from "../src/keeper.ts";
import { RoundError, runRound } from "../src/monitor.ts";
import type { Channel } from "../src/notify/channels.ts";
import type { Probe } from "../src/probe.ts";
import { RECIPIENTS, checkRouting } from "../src/routing.ts";
import type { Notice } from "../src/types.ts";
import { fakeChain, fakeProvider, fixtureSnapshot } from "./fakeChain.ts";

function harness() {
  const sent: { channel: string; n: Notice }[] = [];
  const entries: IncidentEntry[] = [];
  const channel = (name: string): Channel => ({ name, send: async (n) => void sent.push({ channel: name, n }) });
  const routing = checkRouting({ ...Object.fromEntries(RECIPIENTS.map((r) => [r, ["ops"]])), governanceSafeSigners: ["pager"], emergencyGuardianSigners: ["pager"], aaveProtocolGuardian: ["aave"] }, new Set(["ops", "pager", "aave"]));
  const feed = new KeeperFeed([{ name: "eth-primary", chainId: 1 }]);
  const deps = { book: new AlertBook(), feed, probes: [snapshotProbe() as Probe], routing, channels: new Map(["ops", "pager", "aave"].map((c) => [c, channel(c)])), log: { write: (e: IncidentEntry) => void entries.push(e) }, retry: { attempts: 1, backoffMs: 0, sleep: async () => {} } };
  return { sent, entries, deps, feed };
}

const priced = (priceState: number) => (b: { number: bigint; timestamp: number }) => fixtureSnapshot(b, (s) => ({ ...s, markets: s.markets.map((m) => (m.marketId === "1" ? { ...m, priceState } : m)) }));

describe("runRound", () => {
  it("pages a confirmed Expired price to the signers and the Aave contact, once, then resolves it", async () => {
    const { sent, entries, deps, feed } = harness();
    const primary = fakeProvider();
    const second = fakeProvider();
    let block = 100n;
    const chain = fakeChain(() => ({ number: block, timestamp: Number(block) * 12 }), primary, second);
    const beat = () => feed.heartbeat({ name: "eth-primary", chainId: 1 }, block);
    beat();
    expect(await runRound(chain, deps)).toEqual([]);

    block = 101n;
    primary.snapshot = second.snapshot = priced(3);
    beat();
    const opened = await runRound(chain, deps);
    expect(opened.map((n) => `${n.transition}:${n.alert.signal}:${n.alert.level}`)).toEqual(["open:M-01:page"]);
    expect(sent.map((s) => s.channel).sort()).toEqual(["aave", "ops", "pager"]);
    expect(entries[0]).toMatchObject({ signal: "M-01", level: "page", blockNumber: "101", recipients: ["onCall", "operators", "emergencyGuardian", "governanceSafeSigners", "emergencyGuardianSigners", "aaveProtocolGuardian"] });

    block = 102n;
    beat();
    expect(await runRound(chain, deps)).toEqual([]);

    block = 103n;
    primary.snapshot = second.snapshot = priced(0);
    beat();
    expect((await runRound(chain, deps)).map((n) => `${n.transition}:${n.alert.signal}`)).toEqual(["resolve:M-01"]);
  });

  it("sends a page the second provider reads differently as a warn, without the signers", async () => {
    const { sent, deps } = harness();
    const ns = await runRound(fakeChain(() => ({ number: 1n, timestamp: 12 }), fakeProvider({ snapshot: priced(3) }), fakeProvider({ snapshot: priced(2) })), deps);
    expect(ns.map((n) => `${n.alert.signal}:${n.alert.level}:${n.alert.detail.note}`)).toEqual(["M-01:warn:not confirmed on the second provider"]);
    expect(sent.map((s) => s.channel)).toEqual(["ops"]);
  });

  it("pages unconfirmed when the second provider is down", async () => {
    const { deps } = harness();
    const ns = await runRound(fakeChain(() => ({ number: 1n, timestamp: 12 }), fakeProvider({ snapshot: priced(3) }), fakeProvider({ down: true })), deps);
    expect(ns.map((n) => `${n.alert.level}:${n.alert.detail.note}`)).toEqual(["page:unconfirmed, second provider unavailable: ECONNREFUSED"]);
  });

  it("handles the keeper's findings before a failing snapshot read", async () => {
    const { deps } = harness();
    let block = 10n;
    const chain = fakeChain(() => ({ number: block, timestamp: 0 }), fakeProvider({ down: true }), fakeProvider());
    await expect(runRound(chain, deps)).rejects.toThrow(/ECONNREFUSED/);
    expect(deps.book.open()).toEqual([]);
    block = 13n;
    await expect(runRound(chain, deps)).rejects.toThrow(/ECONNREFUSED/);
    expect(deps.book.open().map((a) => `${a.signal}:${a.subject}:${a.level}`)).toEqual(["M-09:keeperInstance:eth-primary:page"]);
  });

  it("runs the other probes when one fails to read, keeps the failed probe's alerts open, and reports it", async () => {
    const { deps } = harness();
    let fail = false;
    const flaky: Probe<number> = {
      name: "flaky",
      read: async () => {
        if (fail) throw new Error("reverted");
        return 1;
      },
      evaluate: () => [{ signal: "M-21", kind: "condition", level: "warn", subject: "x", detail: {} }],
      evidence: () => "1",
    };
    const withFlaky = { ...deps, probes: [flaky as Probe, ...deps.probes] };
    const chain = fakeChain(() => ({ number: 1n, timestamp: 12 }), fakeProvider({ snapshot: priced(2) }), fakeProvider());
    await runRound(chain, withFlaky);
    fail = true;
    await expect(runRound(chain, withFlaky)).rejects.toThrow(RoundError);
    expect(deps.book.open().map((a) => a.signal).sort()).toEqual(["M-01", "M-21"]);
  });
});

describe("loadConfig", () => {
  const manifest = { chainId: 1, avana: { lens: { address: "0x1" }, marketRegistry: { address: "0x2" }, firstLossReserves: [] }, aave: { hubs: [{ address: "0x00000000000000000000000000000000000000a1", label: "Stable", tier: 1, startBlock: 1 }], lendSpokes: [{ address: "0x00000000000000000000000000000000000000a2", label: "Lend", startBlock: 1 }], borrowSpokes: [] } } as unknown as ServiceManifest;
  const base: NodeJS.ProcessEnv = {
    MONITOR_NETWORK_SET: "production",
    AVANA_MANIFEST: "eth.json",
    RPC_MAINNET: "https://a.example",
    RPC_MAINNET_FALLBACK: "https://b.example",
    MONITOR_CHANNELS: "ops:webhook,pd:pagerduty,log:log",
    MONITOR_CHANNEL_OPS_URL: "https://hooks.example/ops",
    MONITOR_CHANNEL_PD_ROUTING_KEY: "rk",
    MONITOR_INCIDENT_LOG: "incidents.jsonl",
    MONITOR_STATUS_TOKEN: "st",
    MONITOR_KEEPER_INSTANCES: "eth-primary:mainnet",
    MONITOR_KEEPER_TOKEN_ETH_PRIMARY: "kt",
    ...Object.fromEntries(RECIPIENTS.map((r) => [routeEnvName(r), "ops,log"])),
  };
  const load = (env: NodeJS.ProcessEnv) => loadConfig(env, () => manifest);

  it("reads a complete configuration", () => {
    const c = load(base);
    expect(c.chains.map((x) => [x.chain.key, x.rpc.second, x.deployment.hubs[0]!.label])).toEqual([["mainnet", "https://b.example", "Stable"]]);
    expect(c.channels.map((x) => x.kind)).toEqual(["webhook", "pagerduty", "log"]);
    expect(c.keeperTokens.get("eth-primary")).toBe("kt");
    expect([c.port, c.intervalSeconds]).toEqual([9470, 12]);
    expect(routeEnvName("riskProviders")).toBe("MONITOR_ROUTE_RISK_PROVIDERS");
  });

  it("refuses a missing second provider, the primary repeated as the second, and a recipient with no channel", () => {
    expect(() => load({ ...base, RPC_MAINNET_FALLBACK: "" })).toThrow(/RPC_MAINNET_FALLBACK/);
    expect(() => load({ ...base, RPC_MAINNET_FALLBACK: "https://a.example" })).toThrow(/second provider/);
    expect(() => load({ ...base, MONITOR_ROUTE_SIGNERS: "" })).toThrow(/no channel for signers/);
    expect(() => load({ ...base, MONITOR_ROUTE_SIGNERS: "sms" })).toThrow(/signers -> sms/);
  });

  it("reads the Safes, the Core Hub GHO asset and the frontend, and refuses malformed entries", () => {
    const safe = "0x00000000000000000000000000000000000005AF";
    const c = load({ ...base, MONITOR_SAFES: `governance:mainnet:${safe}`, MONITOR_CORE_HUB_GHO: `mainnet:${safe}:3`, MONITOR_FRONTEND_URL: "https://app.example", MONITOR_FRONTEND_SHA256: "ab" });
    expect(c.safes.get(1)).toEqual([{ label: "governance", address: safe.toLowerCase() }]);
    expect(c.coreHubGho.get(1)).toEqual({ hub: safe.toLowerCase(), assetId: 3n });
    expect(c.frontend).toEqual({ url: "https://app.example", expectedSha256: "ab", chainId: 1 });
    expect(load(base).frontend).toBeNull();
    expect(() => load({ ...base, MONITOR_SAFES: "g:base:0x1" })).toThrow(/no configured chain/);
    expect(() => load({ ...base, MONITOR_SAFES: "g:mainnet:0x1" })).toThrow(/no valid address/);
    expect(() => load({ ...base, MONITOR_CORE_HUB_GHO: `mainnet:${safe}:x` })).toThrow(/chain:hub:assetId/);
    expect(() => load({ ...base, MONITOR_FRONTEND_URL: "http://app.example" })).toThrow(/https/);
  });

  it("refuses a plain-http webhook, an unknown channel kind, a keeper without token and a manifest of another set", () => {
    expect(() => load({ ...base, MONITOR_CHANNEL_OPS_URL: "http://hooks.example/ops" })).toThrow(/https/);
    expect(() => load({ ...base, MONITOR_CHANNELS: "ops:sms" })).toThrow(/kind sms/);
    expect(() => load({ ...base, MONITOR_KEEPER_TOKEN_ETH_PRIMARY: "" })).toThrow(/MONITOR_KEEPER_TOKEN_ETH_PRIMARY/);
    expect(() => load({ ...base, MONITOR_NETWORK_SET: "testnet" })).toThrow(/no chain of the testnet set/);
  });
});
