// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The oracle probe on a scripted chain: M-01 (DebtOracle), M-02, M-03, M-04 and M-05 at their boundaries, a market
// without a USD band skipped, and a failed read reported as unread.

import { describe, expect, it } from "vitest";
import type { ServiceManifest } from "@avana/services-common";
import { fixtureMarkets } from "@avana/services-common/fixtures";
import { type DebtPrice, type MarketOracle, debtSubject, feedSubject, m02, m03, m04, m05, marketSubject, oracleProbe } from "../src/probes/oracle.ts";
import { EMPTY_MANIFEST, contextOf, fakeProvider, on } from "./fakeChain.ts";

const NOW = 1_800_000_000;
const FEED = "0x00000000000000000000000000000000000000f1";
const DEBT_FEED = "0x00000000000000000000000000000000000000f2";
const SPOKE = "0x5555555555555555555555555555555555555555";
const DEBT_ORACLE = "0x00000000000000000000000000000000000000d1";

const manifest = {
  ...EMPTY_MANIFEST,
  markets: [{ marketId: 1n, feeds: [{ feed: FEED, heartbeatSeconds: 86_400 }] }],
  debtReserves: [
    { spoke: SPOKE, debtReserveId: 1n, asset: "0x1", decimals: 6, isGho: false, debtOracle: { address: DEBT_ORACLE }, feeds: [{ feed: DEBT_FEED, heartbeatSeconds: 86_400 }] },
    { spoke: SPOKE, debtReserveId: 2n, asset: "0x2", decimals: 18, isGho: true, debtOracle: null, feeds: [] },
  ],
} as unknown as ServiceManifest;

const market = (o: Partial<MarketOracle> = {}): MarketOracle => ({ marketId: "1", name: "m", lpOracle: "0x0", disagreeSince: 0n, disagreementPauseMax: 7_200n, usdLevel: 100_000_000n, usdBandLow: 98_000_000n, ...o });
const debt = (o: Partial<DebtPrice> = {}): DebtPrice => ({ spoke: SPOKE, reserveId: "1", state: 0, age: 0n, fixedPrice: false, borrowPriceMaxAge: 3_600n, liquidationPriceMaxAge: 88_200n, ...o });

describe("oracle rules", () => {
  it("M-02 warns from the start and pages 30 minutes before the pause runs out", () => {
    expect(m02(market(), NOW)).toBe("ok");
    expect(m02(market({ disagreeSince: BigInt(NOW - 5_399) }), NOW)).toBe("warn");
    expect(m02(market({ disagreeSince: BigInt(NOW - 5_400) }), NOW)).toBe("page");
  });

  it("M-03 warns above 50 % of feedMaxAge and pages above 90 %", () => {
    const f = (age: number) => m03({ feed: FEED, updatedAt: BigInt(NOW - age), feedMaxAge: 1_000n }, NOW);
    expect([f(500), f(501), f(900), f(901)]).toEqual(["ok", "warn", "warn", "page"]);
    expect(m03({ feed: FEED, updatedAt: 0n, feedMaxAge: 0n }, NOW)).toBeNull();
    expect(m03({ feed: FEED, updatedAt: BigInt(NOW + 5), feedMaxAge: 10n }, NOW)).toBe("ok");
  });

  it("M-04 warns past borrowPriceMaxAge, pages past 90 % of liquidationPriceMaxAge, skips a fixed price", () => {
    expect([3_600n, 3_601n, 79_380n, 79_381n].map((age) => m04(debt({ age })))).toEqual(["ok", "warn", "warn", "page"]);
    expect(m04(debt({ fixedPrice: true, age: 10n ** 9n }))).toBeNull();
  });

  it("M-05 warns below 0.95 and pages below 0.90, only for a market with a band", () => {
    expect([95_000_000n, 94_999_999n, 90_000_000n, 89_999_999n].map((usdLevel) => m05(market({ usdLevel })))).toEqual(["ok", "warn", "warn", "page"]);
    expect(m05(market({ usdBandLow: 0n, usdLevel: 1n }))).toBeNull();
  });
});

describe("oracleProbe", () => {
  function chain(over: { debtState?: number; feedAge?: number; failFeed?: boolean } = {}) {
    return fakeProvider({
      handlers: [
        on("getPriceState", () => ({ usdLevel: 94_000_000n, disagreeSince: BigInt(NOW - 60) })),
        on("getOracleConfig", (args) => ({ usdBandLow: args[0] === fixtureMarkets[1]!.lpOracle ? 0n : 98_000_000n, disagreementPauseMax: 7_200 })),
        on("latestRoundData", () => {
          if (over.failFeed) throw new Error("reverted");
          return [1n, 100_000_000n, 0n, BigInt(NOW - (over.feedAge ?? 10)), 1n];
        }),
        on("getFeed", () => ({ feedMaxAge: 1_000 })),
        on("getDebtPriceState", () => ({ state: over.debtState ?? 0, age: 100n, fixedPrice: false })),
        on("borrowPriceMaxAge", () => 3_600),
        on("liquidationPriceMaxAge", () => 88_200),
      ],
    });
  }
  const run = async (p: ReturnType<typeof chain>) => {
    const probe = oracleProbe();
    const ctx = await contextOf(p, { number: 7n, timestamp: NOW }, manifest);
    const input = await probe.read(ctx);
    return { probe, input, findings: probe.evaluate(input, ctx.block) };
  };
  const byKey = (fs: { signal: string; subject: string; level: string; kind: string }[]) => Object.fromEntries(fs.map((f) => [`${f.signal} ${f.subject}`, f.kind === "unread" ? "unread" : f.level]));

  it("reads every market, feed and DebtOracle the manifest and snapshot list", async () => {
    const { findings } = await run(chain({ debtState: 2, feedAge: 950 }));
    expect(byKey(findings)).toEqual({
      [`M-02 ${marketSubject("1", "disagreement")}`]: "warn",
      [`M-05 ${marketSubject("1", "band")}`]: "warn",
      [`M-02 ${marketSubject("2", "disagreement")}`]: "warn",
      [`M-03 ${feedSubject(FEED)}`]: "page",
      [`M-03 ${feedSubject(DEBT_FEED)}`]: "page",
      [`M-01 ${debtSubject(SPOKE, "1", "state")}`]: "warn",
      [`M-04 ${debtSubject(SPOKE, "1", "age")}`]: "ok",
    });
  });

  it("reports a subject whose read failed as unread, and gives evidence only for read subjects", async () => {
    const { probe, input, findings } = await run(chain({ failFeed: true }));
    expect(byKey(findings)[`M-03 ${feedSubject(FEED)}`]).toBe("unread");
    expect(probe.evidence(input, feedSubject(FEED))).toBeNull();
    expect(probe.evidence(input, debtSubject(SPOKE, "1", "age"))).toContain('"age":"100"');
    expect(probe.evidence(input, marketSubject("1", "band"))).toContain('"usdLevel":"94000000"');
  });
});
