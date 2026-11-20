// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The oracle probe on a scripted chain: M-03 (collateral legs) and M-04 (debt feeds) against each feed's heartbeat at
// their boundaries, and a failed read reported as unread.

import { describe, expect, it } from "vitest";
import type { ServiceManifest } from "@avana/services-common";
import { feedLevel, feedSubject, oracleProbe } from "../src/probes/oracle.ts";
import { EMPTY_MANIFEST, contextOf, fakeProvider, on } from "./fakeChain.ts";

const NOW = 1_800_000_000;
const FEED = "0x00000000000000000000000000000000000000f1";
const DEBT_FEED = "0x00000000000000000000000000000000000000f2";
const SPOKE = "0x5555555555555555555555555555555555555555";

const manifest = {
  ...EMPTY_MANIFEST,
  markets: [{ marketId: 1n, feeds: [{ feed: FEED, heartbeatSeconds: 1_000 }] }],
  debtReserves: [{ spoke: SPOKE, debtReserveId: 1n, asset: "0x1", decimals: 6, isGho: false, feeds: [{ feed: DEBT_FEED, heartbeatSeconds: 1_000 }] }],
} as unknown as ServiceManifest;

describe("feed age", () => {
  it("warns past the heartbeat and pages past 1.5 heartbeats", () => {
    const f = (age: number) => feedLevel({ updatedAt: BigInt(NOW - age), heartbeatSeconds: 1_000n }, NOW);
    expect([f(1_000), f(1_001), f(1_500), f(1_501)]).toEqual(["ok", "warn", "warn", "page"]);
    expect(feedLevel({ updatedAt: 0n, heartbeatSeconds: 0n }, NOW)).toBeNull();
    expect(feedLevel({ updatedAt: BigInt(NOW + 5), heartbeatSeconds: 10n }, NOW)).toBe("ok");
  });
});

describe("oracleProbe", () => {
  const chain = (over: { age?: number; fail?: boolean } = {}) =>
    fakeProvider({
      handlers: [
        on("latestRoundData", () => {
          if (over.fail) throw new Error("reverted");
          return [1n, 100_000_000n, 0n, BigInt(NOW - (over.age ?? 10)), 1n];
        }),
      ],
    });
  const run = async (p: ReturnType<typeof chain>) => {
    const probe = oracleProbe();
    const ctx = await contextOf(p, { number: 7n, timestamp: NOW }, manifest);
    const input = await probe.read(ctx);
    return { probe, input, findings: probe.evaluate(input, ctx.block) };
  };
  const byKey = (fs: { signal: string; subject: string; level: string; kind: string }[]) => Object.fromEntries(fs.map((f) => [`${f.signal} ${f.subject}`, f.kind === "unread" ? "unread" : f.level]));

  it("judges every collateral leg under M-03 and every debt feed under M-04", async () => {
    const { findings } = await run(chain({ age: 1_200 }));
    expect(byKey(findings)).toEqual({ [`M-03 ${feedSubject(FEED)}`]: "warn", [`M-04 ${feedSubject(DEBT_FEED)}`]: "warn" });
  });

  it("reports a feed whose read failed as unread, with no evidence", async () => {
    const { probe, input, findings } = await run(chain({ fail: true }));
    expect(byKey(findings)[`M-03 ${feedSubject(FEED)}`]).toBe("unread");
    expect(probe.evidence(input, feedSubject(FEED))).toBeNull();
  });
});
