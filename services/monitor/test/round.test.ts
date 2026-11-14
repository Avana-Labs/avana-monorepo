// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One round end to end on a scripted chain (snapshot rules, second-provider confirmation, keeper findings, routing,
// delivery and the incident log), and the configuration's refusals.

import { describe, expect, it } from "vitest";
import { FIXTURE_HUB, FIXTURE_LEND, FIXTURE_U, FIXTURE_X, fixtureHubAsset, fixtureMarkets, fixtureSlices, fixtureSpokeReserves } from "@avana/services-common/fixtures";
import type { ServiceManifest } from "@avana/services-common";
import type { ChainSnapshot, MarketRow } from "@avana/services-common/views";
import { AlertBook } from "../src/alertBook.ts";
import { loadConfig, routeEnvName } from "../src/config.ts";
import type { IncidentEntry } from "../src/incidentLog.ts";
import { KeeperFeed } from "../src/keeper.ts";
import { type ChainReads, runRound } from "../src/monitor.ts";
import type { Channel } from "../src/notify/channels.ts";
import { RECIPIENTS, checkRouting } from "../src/routing.ts";
import { SnapshotMemory } from "../src/rules/snapshot.ts";
import type { Notice } from "../src/types.ts";

const snap = (block: bigint, timestamp: number, market1: Partial<MarketRow> = {}): ChainSnapshot => ({
  chainId: 1,
  blockNumber: block.toString(10),
  timestamp,
  hubs: [{ chainId: 1, hub: FIXTURE_HUB, label: "Stable", tier: 1, recorded: true, applicationState: 0, assetCount: 1, lendAssetIds: ["1"], lendSpokes: [FIXTURE_LEND], cdpSpokes: [FIXTURE_U, FIXTURE_X], blockNumber: block.toString(10) }],
  creditLines: [],
  hubAssets: [fixtureHubAsset],
  slices: fixtureSlices,
  spokeReserves: fixtureSpokeReserves,
  markets: fixtureMarkets.map((m) => (m.marketId === "1" ? { ...m, ...market1 } : m)),
});

function harness() {
  const sent: { channel: string; n: Notice }[] = [];
  const entries: IncidentEntry[] = [];
  const channel = (name: string): Channel => ({ name, send: async (n) => void sent.push({ channel: name, n }) });
  const routing = checkRouting({ ...Object.fromEntries(RECIPIENTS.map((r) => [r, ["ops"]])), governanceSafeSigners: ["pager"], emergencyGuardianSigners: ["pager"], aaveProtocolGuardian: ["aave"] }, new Set(["ops", "pager", "aave"]));
  const feed = new KeeperFeed([{ name: "eth-primary", chainId: 1 }]);
  const deps = { book: new AlertBook(), memory: new SnapshotMemory(), feed, routing, channels: new Map(["ops", "pager", "aave"].map((c) => [c, channel(c)])), log: { write: (e: IncidentEntry) => void entries.push(e) }, retry: { attempts: 1, backoffMs: 0, sleep: async () => {} } };
  return { sent, entries, deps, feed };
}

function chain(state: { block: bigint; primary: Partial<MarketRow>; second: Partial<MarketRow> | "down" }): ChainReads {
  return {
    chainId: 1,
    head: async () => ({ number: state.block, timestamp: Number(state.block) * 12 }),
    primary: async (b) => snap(b.number, b.timestamp, state.primary),
    second: async (b) => {
      if (state.second === "down") throw new Error("ECONNREFUSED");
      return snap(b.number, b.timestamp, state.second);
    },
  };
}

describe("runRound", () => {
  it("pages a confirmed Expired price to the signers and the Aave contact, once, then resolves it", async () => {
    const { sent, entries, deps, feed } = harness();
    const state = { block: 100n, primary: {} as Partial<MarketRow>, second: {} as Partial<MarketRow> | "down" };
    feed.heartbeat({ name: "eth-primary", chainId: 1 }, 100n);
    expect(await runRound(chain(state), deps)).toEqual([]);

    Object.assign(state, { block: 101n, primary: { priceState: 3 }, second: { priceState: 3 } });
    feed.heartbeat({ name: "eth-primary", chainId: 1 }, 101n);
    const opened = await runRound(chain(state), deps);
    expect(opened.map((n) => `${n.transition}:${n.alert.signal}:${n.alert.level}`)).toEqual(["open:M-01:page"]);
    expect(sent.map((s) => s.channel).sort()).toEqual(["aave", "ops", "pager"]);
    expect(entries[0]).toMatchObject({ signal: "M-01", level: "page", blockNumber: "101", recipients: ["onCall", "operators", "emergencyGuardian", "governanceSafeSigners", "emergencyGuardianSigners", "aaveProtocolGuardian"] });

    state.block = 102n;
    feed.heartbeat({ name: "eth-primary", chainId: 1 }, 102n);
    expect(await runRound(chain(state), deps)).toEqual([]);

    Object.assign(state, { block: 103n, primary: {}, second: {} });
    feed.heartbeat({ name: "eth-primary", chainId: 1 }, 103n);
    expect((await runRound(chain(state), deps)).map((n) => `${n.transition}:${n.alert.signal}`)).toEqual(["resolve:M-01"]);
  });

  it("sends a page the second provider reads differently as a warn, without the signers", async () => {
    const { sent, deps } = harness();
    const ns = await runRound(chain({ block: 1n, primary: { priceState: 3 }, second: { priceState: 2 } }), deps);
    expect(ns.map((n) => `${n.alert.signal}:${n.alert.level}:${n.alert.detail.note}`)).toEqual(["M-01:warn:not confirmed on the second provider"]);
    expect(sent.map((s) => s.channel)).toEqual(["ops"]);
  });

  it("handles the keeper's findings before a failing snapshot read", async () => {
    const { deps } = harness();
    const reads: ChainReads = { ...chain({ block: 10n, primary: {}, second: {} }), primary: async () => { throw new Error("RPC down"); } };
    // First round: the monitor's start, from which the never-heard instance is counted.
    await expect(runRound({ ...reads, head: async () => ({ number: 10n, timestamp: 0 }) }, deps)).rejects.toThrow(/RPC down/);
    expect(deps.book.open()).toEqual([]);
    await expect(runRound({ ...reads, head: async () => ({ number: 13n, timestamp: 36 }) }, deps)).rejects.toThrow(/RPC down/);
    expect(deps.book.open().map((a) => `${a.signal}:${a.subject}:${a.level}`)).toEqual(["M-09:keeperInstance:eth-primary:page"]);
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

  it("refuses a plain-http webhook, an unknown channel kind, a keeper without token and a manifest of another set", () => {
    expect(() => load({ ...base, MONITOR_CHANNEL_OPS_URL: "http://hooks.example/ops" })).toThrow(/https/);
    expect(() => load({ ...base, MONITOR_CHANNELS: "ops:sms" })).toThrow(/kind sms/);
    expect(() => load({ ...base, MONITOR_KEEPER_TOKEN_ETH_PRIMARY: "" })).toThrow(/MONITOR_KEEPER_TOKEN_ETH_PRIMARY/);
    expect(() => load({ ...base, MONITOR_NETWORK_SET: "testnet" })).toThrow(/no chain of the testnet set/);
  });
});
