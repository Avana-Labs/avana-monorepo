// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The gas vault probe, read from the chain: M-35 judges the vault's balance against what it sent per day (30 days
// warns, 14 pages, never below the configured expected spend, only once the log reads have caught up); M-36 pages once
// for each top-up below its request and each failed top-up, confirmed on the second provider; the probe's window and
// read position survive a restart; a manifest without a vault gives nothing.

import { describe, expect, it } from "vitest";
import { type Address, type Hex, encodeAbiParameters, encodeEventTopics } from "viem";
import { avanaGasVaultAbi } from "@avana/protocol/abis";
import type { ServiceManifest } from "@avana/services-common";
import { AlertBook } from "../src/alertBook.ts";
import { KeeperFeed } from "../src/keeper.ts";
import { runRound } from "../src/monitor.ts";
import type { Channel } from "../src/notify/channels.ts";
import type { Probe, RawLog } from "../src/probe.ts";
import { dailyRate, gasVaultProbe, m35, runwaySubject, topUpSubject } from "../src/probes/gasVault.ts";
import { RECIPIENTS, checkRouting } from "../src/routing.ts";
import { EMPTY_MANIFEST, type FakeProvider, contextOf, fakeChain, fakeProvider, on } from "./fakeChain.ts";

const NOW = 1_800_000_000;
const DAY = 86_400;
const ETHER = 10n ** 18n;
const VAULT = "0x00000000000000000000000000000000000000c1" as Address;
const SIGNER = "0x00000000000000000000000000000000000000c2" as Address;
const CALLER = "0x00000000000000000000000000000000000000c3" as Address;

const manifest = { ...EMPTY_MANIFEST, avana: { ...EMPTY_MANIFEST.avana, gasVault: { address: VAULT, codeHash: `0x${"00".repeat(32)}`, startBlock: 10, artifact: null, treasury: CALLER, timelock: CALLER, guardian: CALLER, maxSigners: 8 } } } as unknown as ServiceManifest;

let logIndex = 0;
function toppedUp(block: bigint, amount: bigint, requested: bigint): RawLog {
  const topics = encodeEventTopics({ abi: avanaGasVaultAbi, eventName: "ToppedUp", args: { signer: SIGNER, caller: CALLER } }) as Hex[];
  return { address: VAULT, topics, data: encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [amount, requested]), blockNumber: block, transactionHash: `0x${block.toString(16).padStart(64, "0")}`, logIndex: logIndex++ };
}
function failed(block: bigint, amount: bigint): RawLog {
  const topics = encodeEventTopics({ abi: avanaGasVaultAbi, eventName: "TopUpFailed", args: { signer: SIGNER } }) as Hex[];
  return { address: VAULT, topics, data: encodeAbiParameters([{ type: "uint256" }], [amount]), blockNumber: block, transactionHash: `0x${"f".repeat(63)}${block % 10n}`, logIndex: logIndex++ };
}

function provider(balance: () => bigint, logs: RawLog[] = []): FakeProvider {
  return fakeProvider({ handlers: [on("getEthBalance", () => balance())], logs });
}

function harness(probe: Probe) {
  const routing = checkRouting(Object.fromEntries(RECIPIENTS.map((r) => [r, ["ops"]])), new Set(["ops"]));
  const channel: Channel = { name: "ops", send: async () => {} };
  return { book: new AlertBook(), feed: new KeeperFeed([]), probes: [probe], routing, channels: new Map([["ops", channel]]), log: { write: () => {} }, retry: { attempts: 1, backoffMs: 0, sleep: async () => {} } };
}

describe("M-35 gas vault runway", () => {
  it("warns under 30 days and pages under 14 days of daily top-ups", () => {
    expect([m35(30n * ETHER, ETHER), m35(30n * ETHER - 1n, ETHER), m35(14n * ETHER, ETHER), m35(14n * ETHER - 1n, ETHER), m35(0n, 0n)]).toEqual(["ok", "warn", "warn", "page", "ok"]);
  });

  it("measures the rate over the days watched, at most 30, at least one", () => {
    const sent = [{ t: NOW - 40 * DAY, amount: 100n * ETHER }, { t: NOW - 2 * DAY, amount: 6n * ETHER }, { t: NOW - DAY / 2, amount: 3n * ETHER }];
    expect(dailyRate(sent, NOW - 60 * DAY, NOW)).toBe((9n * ETHER) / 30n); // the 40-day-old top-up left the window
    expect(dailyRate(sent, NOW - 3 * DAY, NOW)).toBe(3n * ETHER); // 9 ETH over 3 days watched
    expect(dailyRate([], NOW - 3 * DAY, NOW)).toBe(0n);
  });

  it("uses the expected daily spend as a floor and judges only once caught up with the head", async () => {
    const probe = gasVaultProbe(ETHER);
    // 20 ETH held, 1 ETH a day expected: 20 days of runway warns.
    const p = provider(() => 20n * ETHER);
    const judge = async (number: bigint, timestamp: number) => probe.evaluate(await probe.read(await contextOf(p, { number, timestamp }, manifest)), { number, timestamp });
    // From the deployment block (10) the first round reads 10…2,009 and is not caught up with 5,000: unread.
    expect((await judge(5_000n, NOW)).map((f) => [f.signal, f.kind])).toEqual([["M-35", "unread"]]);
    await judge(5_001n, NOW + 12); // 2,010…4,009
    const [f] = await judge(5_002n, NOW + 24); // 4,010…5,002: caught up
    expect(f).toMatchObject({ signal: "M-35", kind: "condition", level: "warn", subject: runwaySubject(VAULT), detail: { runwayDays: "20", dailyTopUpWei: ETHER.toString() } });
  });

  it("pages when what the vault sent per day leaves under 14 days, confirmed on the second provider", async () => {
    // Watched for 2 days; 10 ETH sent over them is 5 ETH a day; 60 ETH left is 12 days.
    let time = NOW;
    let block = 100n;
    const logs = [toppedUp(50n, 10n * ETHER, 10n * ETHER)];
    const probe = gasVaultProbe();
    const chain = fakeChain(() => ({ number: block, timestamp: time }), provider(() => 60n * ETHER, logs), provider(() => 60n * ETHER, logs), manifest);
    const deps = harness(probe as Probe);
    await runRound(chain, deps);
    time = NOW + 2 * DAY;
    block = 200n;
    const notices = await runRound(chain, deps);
    expect(notices.map((n) => `${n.transition}:${n.alert.signal}:${n.alert.level}`)).toEqual(["open:M-35:page"]);

    // The second provider reads a larger balance at the same block: sent as a warn.
    const p2 = gasVaultProbe();
    const split = fakeChain(() => ({ number: block, timestamp: time }), provider(() => 60n * ETHER, logs), provider(() => 600n * ETHER, logs), manifest);
    const d2 = harness(p2 as Probe);
    time = NOW;
    block = 100n;
    await runRound(split, d2);
    time = NOW + 2 * DAY;
    block = 200n;
    const [n] = await runRound(split, d2);
    expect(n).toMatchObject({ alert: { signal: "M-35", level: "warn", detail: { note: "not confirmed on the second provider" } } });
  });
});

describe("M-36 gas vault top-up capped", () => {
  it("pages once for a top-up below its request and for a failed top-up, never for a full one", async () => {
    const logs = [toppedUp(20n, 5n * ETHER, 5n * ETHER), toppedUp(21n, 2n * ETHER, 7n * ETHER), failed(22n, 3n * ETHER)];
    const probe = gasVaultProbe();
    const input = await probe.read(await contextOf(provider(() => 100n * ETHER, logs), { number: 30n, timestamp: NOW }, manifest));
    const pages = probe.evaluate(input, { number: 30n, timestamp: NOW }).filter((f) => f.signal === "M-36");
    expect(pages.map((f) => [f.level, f.detail.event, f.detail.amount, f.detail.requested])).toEqual([
      ["page", "ToppedUp", (2n * ETHER).toString(), (7n * ETHER).toString()],
      ["page", "TopUpFailed", (3n * ETHER).toString(), (3n * ETHER).toString()],
    ]);
    expect(probe.evidence(input, pages[0]!.subject)).not.toBeNull();
    // The next round reads from block 31: the same events are not paged again.
    const again = probe.evaluate(await probe.read(await contextOf(provider(() => 100n * ETHER, logs), { number: 31n, timestamp: NOW + 12 }, manifest)), { number: 31n, timestamp: NOW + 12 });
    expect(again.filter((f) => f.signal === "M-36")).toEqual([]);
  });

  it("keeps its read position and window across a restart", async () => {
    const logs = [toppedUp(20n, 4n * ETHER, 4n * ETHER)];
    const before = gasVaultProbe();
    before.evaluate(await before.read(await contextOf(provider(() => 100n * ETHER, logs), { number: 30n, timestamp: NOW }, manifest)), { number: 30n, timestamp: NOW });
    const after = gasVaultProbe();
    after.restore!(JSON.parse(JSON.stringify(before.save!())));
    const input = await after.read(await contextOf(provider(() => 100n * ETHER, logs), { number: 40n, timestamp: NOW + 2 * DAY }, manifest));
    expect(input.from).toBe(31n);
    const [f] = after.evaluate(input, { number: 40n, timestamp: NOW + 2 * DAY });
    expect(f).toMatchObject({ signal: "M-35", detail: { measuredDailyWei: (2n * ETHER).toString() } });
  });

  it("gives nothing without a vault in the manifest", async () => {
    const probe = gasVaultProbe(ETHER);
    const input = await probe.read(await contextOf(provider(() => 0n), { number: 30n, timestamp: NOW }));
    expect(probe.evaluate(input, { number: 30n, timestamp: NOW })).toEqual([]);
    expect(topUpSubject({ tx: "0x01", logIndex: 2 })).toBe("gasVault:topUp:0x01:2");
  });
});
