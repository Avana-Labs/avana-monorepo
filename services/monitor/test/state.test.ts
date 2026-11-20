// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A restart through the state file: open alerts are not sent again, the events probe resumes where it stopped (events
// during downtime are read), a Safe changed while the monitor was down is reported, and a bad file stops the process.

import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { type Abi, type Address, encodeAbiParameters, encodeEventTopics, type Hex } from "viem";
import { accessManagerAbi } from "@avana/protocol/abis";
import type { ServiceManifest } from "@avana/services-common";
import { AlertBook } from "../src/alertBook.ts";
import { snapshotProbe } from "../src/confirm.ts";
import { KeeperFeed } from "../src/keeper.ts";
import { runRound } from "../src/monitor.ts";
import type { Probe, RawLog } from "../src/probe.ts";
import { eventsProbe } from "../src/probes/events.ts";
import { safesProbe } from "../src/probes/external.ts";
import { RECIPIENTS, checkRouting } from "../src/routing.ts";
import { STATE_VERSION, apply, collect, decode, encode, fileStateStore } from "../src/state.ts";
import type { Notice } from "../src/types.ts";
import { EMPTY_MANIFEST, fakeChain, fakeProvider, fixtureSnapshot, on } from "./fakeChain.ts";

const MANAGER = "0x0000000000000000000000000000000000000071" as Address;
const SAFE = "0x00000000000000000000000000000000000005af" as Address;
const manifest = { ...EMPTY_MANIFEST, avana: { ...EMPTY_MANIFEST.avana, accessManager: { address: MANAGER } }, aave: { hubs: [], lendSpokes: [], borrowSpokes: [] } } as unknown as ServiceManifest;

/** An AccessManager role grant (M-22, a page). */
function granted(block: bigint, n: number): RawLog {
  const ev = (accessManagerAbi as Abi).find((e) => e.type === "event" && e.name === "RoleGranted") as Extract<Abi[number], { type: "event" }>;
  const values: Record<string, unknown> = { roleId: 101n, account: MANAGER, delay: 0, since: 5, newMember: true };
  const topics = encodeEventTopics({ abi: [ev], eventName: "RoleGranted", args: Object.fromEntries(ev.inputs.filter((i) => i.indexed).map((i) => [i.name!, values[i.name!]])) } as never) as Hex[];
  const plain = ev.inputs.filter((i) => !i.indexed);
  return { address: MANAGER, topics, data: encodeAbiParameters(plain, plain.map((i) => values[i.name!])), blockNumber: block, transactionHash: `0x${n.toString(16).padStart(64, "0")}`, logIndex: 0 };
}

function monitor() {
  const sent: Notice[] = [];
  const routing = checkRouting(Object.fromEntries(RECIPIENTS.map((r) => [r, ["ops"]])), new Set(["ops"]));
  const probes = [snapshotProbe(), eventsProbe(), safesProbe([{ label: "governance", address: SAFE }])] as Probe[];
  const deps = { book: new AlertBook(), feed: new KeeperFeed([]), probes, routing, channels: new Map([["ops", { name: "ops", send: async (n: Notice) => void sent.push(n) }]]), log: { write: () => {} }, retry: { attempts: 1, backoffMs: 0, sleep: async () => {} } };
  return { sent, deps, parts: { book: deps.book, feed: deps.feed, probes: new Map([[1, probes]]) } };
}

describe("restart through the state file", () => {
  it("keeps open alerts quiet, reads events from downtime and reports a Safe changed meanwhile", async () => {
    let owners = ["0xa", "0xb"];
    const p = fakeProvider({
      snapshot: (b) => fixtureSnapshot(b, (s) => ({ ...s, markets: s.markets.map((m) => (m.marketId === "1" ? { ...m, priceAvailable: false } : m)) })),
      handlers: [on("getOwners", () => owners), on("getThreshold", () => 2n), on("getModulesPaginated", () => [[], "0x1"])],
    });
    let block = 100n;
    const chain = fakeChain(() => ({ number: block, timestamp: Number(block) * 12 }), p, p, manifest);
    const store = fileStateStore(join(mkdtempSync(join(tmpdir(), "monitor-state-")), "state.json"));

    const first = monitor();
    expect((await runRound(chain, first.deps)).map((n) => n.alert.signal)).toEqual(["M-01"]);
    store.save(collect(first.parts, 1));

    // Down for blocks 101..110: a role is granted at 105 and a Safe owner is swapped.
    p.logs.push(granted(105n, 1));
    owners = ["0xa", "0xc"];
    block = 110n;

    const second = monitor();
    apply(second.parts, store.load()!);
    const ns = await runRound(chain, second.deps);
    expect(ns.map((n) => `${n.transition}:${n.alert.signal}`)).toEqual(["event:M-22", "event:M-23"]);
    expect(second.deps.book.open().map((a) => a.signal)).toEqual(["M-01"]);
  });

  it("round-trips bigints, maps and sets exactly", () => {
    const v = { a: 2n ** 200n, m: new Map([["k", [{ t: 1, v: 3n }]]]), s: new Set(["x"]), n: null, big: { $big: "not alone", x: 1 } };
    expect(decode(encode(v))).toEqual(v);
  });

  it("starts fresh without a file and refuses a file of another version", () => {
    const dir = mkdtempSync(join(tmpdir(), "monitor-state-"));
    expect(fileStateStore(join(dir, "none.json")).load()).toBeNull();
    const path = join(dir, "old.json");
    writeFileSync(path, encode({ version: STATE_VERSION + 1 }));
    expect(() => fileStateStore(path).load()).toThrow(/version/);
  });
});
