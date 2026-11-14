// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Safe signer liveness: answers signed by the owners' keys, checked and counted per period; the Safe pages once the
// answer window passes with fewer than threshold + 1 current owners answering; the endpoint refuses bad answers.

import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { LivenessBook, acceptAnswer, livenessMessage } from "../src/liveness.ts";
import { KeeperFeed } from "../src/keeper.ts";
import { safesProbe } from "../src/probes/external.ts";
import { monitorServer } from "../src/server.ts";
import { contextOf, fakeProvider, on } from "./fakeChain.ts";

const SAFE = "0x00000000000000000000000000000000000005af";
const keys = ["11", "22", "33", "44"].map((b) => `0x${b.repeat(32)}` as `0x${string}`);
const signers = keys.map((k) => privateKeyToAccount(k));
const DAY = 86_400;
const cfg = { periodSeconds: DAY, windowSeconds: DAY / 2 };
const T0 = 20_000 * DAY; // the start of period 20,000

async function answer(book: LivenessBook, signer: number, now: number, over: Partial<{ period: number; safe: string; claimed: string }> = {}) {
  const period = over.period ?? book.periodOf(now);
  const safe = over.safe ?? SAFE;
  const signature = await signers[signer]!.signMessage({ message: livenessMessage(1, safe, period) });
  return acceptAnswer(book, (c, s) => c === 1 && s.toLowerCase() === SAFE, { chainId: 1, safe, period, signer: over.claimed ?? signers[signer]!.address, signature }, now);
}

describe("LivenessBook", () => {
  it("judges the previous period until the current one's window has passed", () => {
    const book = new LivenessBook(cfg);
    expect(book.judgedPeriod(T0)).toBe(19_999);
    expect(book.judgedPeriod(T0 + DAY / 2 - 1)).toBe(19_999);
    expect(book.judgedPeriod(T0 + DAY / 2)).toBe(20_000);
  });

  it("accepts an owner's signed answer for the current period and refuses the rest", async () => {
    const book = new LivenessBook(cfg);
    expect(await answer(book, 0, T0 + 10)).toBeNull();
    expect(await answer(book, 1, T0 + 10, { period: 19_999 })).toMatch(/not the current period/);
    expect(await answer(book, 1, T0 + 10, { claimed: signers[2]!.address })).toMatch(/not the named signer/);
    expect(await answer(book, 1, T0 + 10, { safe: "0x00000000000000000000000000000000000000aa" })).toMatch(/not a watched Safe/);
    expect(await acceptAnswer(book, () => true, { chainId: 1, safe: SAFE, period: 20_000, signer: signers[0]!.address, signature: "0x12" }, T0)).toMatch(/malformed/);
    expect(book.answered(1, SAFE, 20_000, signers.map((s) => s.address))).toEqual([signers[0]!.address.toLowerCase()]);
  });
});

describe("Safe liveness in the Safes probe", () => {
  it("pages below threshold + 1 answering owners once the window passed, counting current owners only", async () => {
    const book = new LivenessBook(cfg);
    const owners = signers.slice(0, 3).map((s) => s.address);
    const p = fakeProvider({ handlers: [on("getOwners", () => owners), on("getThreshold", () => 2n), on("getModulesPaginated", () => [[], "0x1"])] });
    const probe = safesProbe([{ label: "governance", address: SAFE }], { book, chainId: 1 });
    const level = async (t: number) => {
      const ctx = await contextOf(p, { number: BigInt(t), timestamp: t });
      return probe.evaluate(await probe.read(ctx), ctx.block).filter((f) => f.subject.endsWith(":liveness")).map((f) => `${f.level}:${f.detail.answered}/${f.detail.needed}`);
    };
    expect(await level(T0 + 60)).toEqual([]); // the monitor started in period 20,000: period 19,999 is not judged
    await answer(book, 0, T0 + 100);
    await answer(book, 1, T0 + 200);
    await answer(book, 3, T0 + 300); // not an owner
    expect(await level(T0 + DAY / 2)).toEqual(["page:2/3"]);
    await answer(book, 2, T0 + DAY / 2 + 5);
    expect(await level(T0 + DAY / 2 + 10)).toEqual(["ok:3/3"]);
    expect(await level(T0 + DAY + 60)).toEqual(["ok:3/3"]); // period 20,001's window is still open
    expect(await level(T0 + DAY + DAY / 2)).toEqual(["page:0/3"]);
  });
});

describe("liveness endpoint", () => {
  let close: (() => void) | null = null;
  afterEach(() => close?.());

  it("records a valid answer and refuses an invalid one with 422", async () => {
    const book = new LivenessBook(cfg);
    const server = monitorServer({ keeperTokens: new Map(), statusToken: "s" }, new KeeperFeed([]), () => [], undefined, { book, watched: (c, s) => c === 1 && s.toLowerCase() === SAFE, now: () => T0 + 5 });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    close = () => server.close();
    const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1/liveness`;
    const post = (body: unknown) => fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    const signature = await signers[0]!.signMessage({ message: livenessMessage(1, SAFE, 20_000) });
    expect((await post({ chainId: 1, safe: SAFE, period: 20_000, signer: signers[0]!.address, signature })).status).toBe(200);
    const bad = await post({ chainId: 1, safe: SAFE, period: 20_000, signer: signers[1]!.address, signature });
    expect([bad.status, ((await bad.json()) as { error: string }).error]).toEqual([422, "signature is not the named signer's"]);
    expect(book.answered(1, SAFE, 20_000, [signers[0]!.address])).toHaveLength(1);
  });
});
