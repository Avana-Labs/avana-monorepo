// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The oracle probe on a scripted chain: M-01 (debt price), M-03, M-04 and M-05 at their boundaries, a market without a
// USD band skipped, the debt age limits read from the source feed's ParameterStore ages, and a failed read reported
// as unread.

import { describe, expect, it } from "vitest";
import type { ServiceManifest } from "@avana/services-common";
import { fixtureMarkets } from "@avana/services-common/fixtures";
import { type DebtPrice, type MarketOracle, debtSubject, feedSubject, m03, m04, m05, marketSubject, oracleProbe, usdLevelOf } from "../src/probes/oracle.ts";
import { EMPTY_MANIFEST, contextOf, fakeProvider, on } from "./fakeChain.ts";

const NOW = 1_800_000_000;
const FEED = "0x00000000000000000000000000000000000000f1";
const DEBT_FEED = "0x00000000000000000000000000000000000000f2";
const SPOKE = "0x5555555555555555555555555555555555555555";

const manifest = {
  ...EMPTY_MANIFEST,
  markets: [{ marketId: 1n, feeds: [{ feed: FEED, heartbeatSeconds: 86_400 }] }],
  debtReserves: [
    { spoke: SPOKE, debtReserveId: 1n, asset: "0x1", decimals: 6, isGho: false, feeds: [{ feed: DEBT_FEED, heartbeatSeconds: 86_400 }] },
    { spoke: SPOKE, debtReserveId: 2n, asset: "0x2", decimals: 18, isGho: true, feeds: [] },
  ],
} as unknown as ServiceManifest;

const market = (o: Partial<MarketOracle> = {}): MarketOracle => ({ marketId: "1", name: "m", lpOracle: "0x0", usdLevel: 100_000_000n, usdBandLow: 98_000_000n, ...o });
const debt = (o: Partial<DebtPrice> = {}): DebtPrice => ({ spoke: SPOKE, reserveId: "1", source: DEBT_FEED, state: 0, age: 0n, fixedPrice: false, borrowPriceMaxAge: 3_600n, liquidationPriceMaxAge: 88_200n, ...o });

describe("oracle rules", () => {
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

  it("takes the USD level as √(p0·p1) of two token prices, rounded down", () => {
    expect(usdLevelOf([100_000_000n, 81_000_000n])).toBe(90_000_000n);
    expect(usdLevelOf([100_000_000n, 100_000_001n])).toBe(100_000_000n);
    expect(usdLevelOf([97_000_000n])).toBe(97_000_000n);
  });
});

describe("oracleProbe", () => {
  function chain(over: { debtState?: number; feedAge?: number; failFeed?: boolean } = {}) {
    const ageArgs: unknown[] = [];
    const provider = fakeProvider({
      handlers: [
        on("getTokenPrices", () => [[94_000_000n, 94_000_000n], BigInt(NOW - 60)]),
        on("getOracleConfig", (args) => ({ usdBandLow: args[0] === fixtureMarkets[1]!.lpOracle ? 0n : 98_000_000n })),
        on("latestRoundData", () => {
          if (over.failFeed) throw new Error("reverted");
          return [1n, 100_000_000n, 0n, BigInt(NOW - (over.feedAge ?? 10)), 1n];
        }),
        on("getFeed", () => ({ feedMaxAge: 1_000 })),
        on("getDebtPriceState", () => ({ source: DEBT_FEED, state: over.debtState ?? 0, age: 100n, fixedPrice: false })),
        on("borrowPriceMaxAge", (args) => {
          ageArgs.push(args[0]);
          return 3_600;
        }),
        on("liquidationPriceMaxAge", () => 88_200),
      ],
    });
    return { provider, ageArgs };
  }
  const run = async (p: ReturnType<typeof chain>["provider"]) => {
    const probe = oracleProbe();
    const ctx = await contextOf(p, { number: 7n, timestamp: NOW }, manifest);
    const input = await probe.read(ctx);
    return { probe, input, findings: probe.evaluate(input, ctx.block) };
  };
  const byKey = (fs: { signal: string; subject: string; level: string; kind: string }[]) => Object.fromEntries(fs.map((f) => [`${f.signal} ${f.subject}`, f.kind === "unread" ? "unread" : f.level]));

  it("reads every market, feed and non-GHO debt reserve the manifest and snapshot list", async () => {
    const { provider, ageArgs } = chain({ debtState: 2, feedAge: 950 });
    const { findings } = await run(provider);
    expect(byKey(findings)).toEqual({
      [`M-05 ${marketSubject("1", "band")}`]: "warn",
      [`M-03 ${feedSubject(FEED)}`]: "page",
      [`M-03 ${feedSubject(DEBT_FEED)}`]: "page",
      [`M-01 ${debtSubject(SPOKE, "1", "state")}`]: "warn",
      [`M-04 ${debtSubject(SPOKE, "1", "age")}`]: "ok",
    });
    // The debt age limits are the ParameterStore ages of the feed the Lens names as the reserve's source.
    expect(ageArgs).toEqual([DEBT_FEED]);
  });

  it("reports a subject whose read failed as unread, and gives evidence only for read subjects", async () => {
    const { probe, input, findings } = await run(chain({ failFeed: true }).provider);
    expect(byKey(findings)[`M-03 ${feedSubject(FEED)}`]).toBe("unread");
    expect(probe.evidence(input, feedSubject(FEED))).toBeNull();
    expect(probe.evidence(input, debtSubject(SPOKE, "1", "age"))).toContain('"age":"100"');
    expect(probe.evidence(input, marketSubject("1", "band"))).toContain('"usdLevel":"94000000"');
  });
});
