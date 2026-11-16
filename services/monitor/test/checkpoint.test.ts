// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// M-34, oracle poke overdue, read from the chain: a market whose LPOracle checkpoint is older than 7,200 s pages, the
// page is confirmed on the second provider at the same block (a provider that reads a newer checkpoint turns it into a
// warn), and the alert resolves once a poke stores a new checkpoint.

import { describe, expect, it } from "vitest";
import { fixtureMarkets } from "@avana/services-common/fixtures";
import { AlertBook } from "../src/alertBook.ts";
import { KeeperFeed } from "../src/keeper.ts";
import { runRound } from "../src/monitor.ts";
import type { Channel } from "../src/notify/channels.ts";
import type { Probe } from "../src/probe.ts";
import { CHECKPOINT_OVERDUE_SECONDS, checkpointProbe, checkpointSubject, m34 } from "../src/probes/checkpoint.ts";
import { RECIPIENTS, checkRouting } from "../src/routing.ts";
import type { Notice } from "../src/types.ts";
import { type FakeProvider, contextOf, fakeChain, fakeProvider, on } from "./fakeChain.ts";

const NOW = 1_800_000_000;
const [M1, M2] = fixtureMarkets as [(typeof fixtureMarkets)[number], (typeof fixtureMarkets)[number]];

/** A provider whose LPOracles answer `priceCheckpoint()` with the given `at` per oracle (market 2 always fresh). */
function provider(at: () => number): FakeProvider {
  return fakeProvider({
    handlers: [on("priceCheckpoint", () => [10n ** 8n, BigInt(at())], M1.lpOracle), on("priceCheckpoint", () => [10n ** 8n, BigInt(NOW - 60)], M2.lpOracle)],
  });
}

function harness() {
  const sent: Notice[] = [];
  const channel: Channel = { name: "ops", send: async (n) => void sent.push(n) };
  const routing = checkRouting(Object.fromEntries(RECIPIENTS.map((r) => [r, ["ops"]])), new Set(["ops"]));
  const deps = { book: new AlertBook(), feed: new KeeperFeed([]), probes: [checkpointProbe() as Probe], routing, channels: new Map([["ops", channel]]), log: { write: () => {} }, retry: { attempts: 1, backoffMs: 0, sleep: async () => {} } };
  return { sent, deps };
}

describe("M-34 poke overdue", () => {
  it("pagesAt7200s", async () => {
    expect(CHECKPOINT_OVERDUE_SECONDS).toBe(7_200);
    expect([m34(BigInt(NOW - 7_200), NOW), m34(BigInt(NOW - 7_201), NOW), m34(0n, NOW)]).toEqual(["ok", "page", "page"]);

    let at = NOW - 7_200;
    const probe = checkpointProbe();
    const p = provider(() => at);
    const judge = async () => probe.evaluate(await probe.read(await contextOf(p, { number: 7n, timestamp: NOW })), { number: 7n, timestamp: NOW });
    expect((await judge()).map((f) => [f.subject, f.level])).toEqual([[checkpointSubject(M1.marketId), "ok"], [checkpointSubject(M2.marketId), "ok"]]);
    at = NOW - 7_201;
    const findings = await judge();
    expect(findings[0]).toMatchObject({ signal: "M-34", kind: "condition", level: "page", subject: checkpointSubject(M1.marketId), detail: { ageSeconds: "7201", lpOracle: M1.lpOracle } });
    expect(findings[1]!.level).toBe("ok"); // any market: each is judged on its own
  });

  it("confirmedOnSecondProvider", async () => {
    // Both providers read the old checkpoint: a page.
    const both = harness();
    const stale = () => NOW - 9_000;
    const chain = fakeChain(() => ({ number: 100n, timestamp: NOW }), provider(stale), provider(stale));
    expect((await runRound(chain, both.deps)).map((n) => `${n.transition}:${n.alert.signal}:${n.alert.level}`)).toEqual(["open:M-34:page"]);

    // The second provider reads a fresh checkpoint at the same block: sent as a warn, with the note.
    const split = harness();
    const disagree = fakeChain(() => ({ number: 100n, timestamp: NOW }), provider(stale), provider(() => NOW - 60));
    const [n] = await runRound(disagree, split.deps);
    expect(n).toMatchObject({ transition: "open", alert: { signal: "M-34", level: "warn", detail: { note: "not confirmed on the second provider" } } });

    // An unreadable market is unread, not resolved, and gives no evidence.
    const probe = checkpointProbe();
    const failing = fakeProvider({ handlers: [on("priceCheckpoint", () => { throw new Error("reverted"); })] });
    const input = await probe.read(await contextOf(failing, { number: 7n, timestamp: NOW }));
    expect(probe.evaluate(input, { number: 7n, timestamp: NOW }).map((f) => f.kind)).toEqual(["unread", "unread"]);
    expect(probe.evidence(input, checkpointSubject(M1.marketId))).toBeNull();
  });

  it("resolvesAfterPoke", async () => {
    const { sent, deps } = harness();
    let at = NOW - 8_000;
    let block = 100n;
    let time = NOW;
    const chain = fakeChain(() => ({ number: block, timestamp: time }), provider(() => at), provider(() => at));
    expect((await runRound(chain, deps)).map((n) => n.transition)).toEqual(["open"]);
    block = 101n;
    time = NOW + 12;
    expect(await runRound(chain, deps)).toEqual([]); // a page that stays true is sent once
    block = 102n;
    time = NOW + 24;
    at = NOW + 24; // the keeper's poke stored a new checkpoint
    const resolved = await runRound(chain, deps);
    expect(resolved.map((n) => `${n.transition}:${n.alert.signal}:${n.alert.subject}`)).toEqual([`resolve:M-34:${checkpointSubject(M1.marketId)}`]);
    expect(sent).toHaveLength(2);
  });
});
