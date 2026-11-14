// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The coverage probe on a scripted chain: M-07, M-13 (reserve and offset), M-14, M-21 and M-28 at their boundaries.

import { describe, expect, it } from "vitest";
import { FIXTURE_HUB, FIXTURE_USDC, fixtureMarkets } from "@avana/services-common/fixtures";
import { type Tail, coverageProbe, m07, m13Offset, m13Reserve, m14, tailKey } from "../src/probes/coverage.ts";
import { contextOf, fakeProvider, on } from "./fakeChain.ts";

const OFFSET = "0x00000000000000000000000000000000000000d0";
const tail = (o: Partial<Tail> = {}): Tail => ({ hub: FIXTURE_HUB, asset: FIXTURE_USDC, funded: 300n, minimum: 200n, ratioBps: 20_000n, deficitOffset: OFFSET, offsetFunded: 100n, offsetMinimum: 100n, ...o });

describe("coverage rules", () => {
  it("M-07 warns above 75 % of the pool-share maximum and pages above it", () => {
    const at = (bps: bigint) => m07({ name: "m", poolShareBps: bps, poolShareMaxBps: 2_000n, backingBroken: [] });
    expect([1_500n, 1_501n, 2_000n, 2_001n].map(at)).toEqual(["ok", "warn", "warn", "page"]);
    expect(m07({ name: "m", poolShareBps: 9n, poolShareMaxBps: 0n, backingBroken: [] })).toBeNull();
  });

  it("M-13 warns below 150 % of the reserve minimum, pages below 100 %, and warns on an offset below its size", () => {
    expect([300n, 299n, 200n, 199n].map((funded) => m13Reserve(tail({ funded })))).toEqual(["ok", "warn", "warn", "page"]);
    expect(m13Reserve(tail({ minimum: 0n }))).toBeNull();
    expect([m13Offset(tail()), m13Offset(tail({ offsetFunded: 99n })), m13Offset(tail({ offsetMinimum: null }))]).toEqual(["ok", "warn", null]);
  });

  it("M-14 warns below 150 % and pages below 100 %", () => {
    expect([15_000n, 14_999n, 10_000n, 9_999n].map((ratioBps) => m14(tail({ ratioBps })))).toEqual(["ok", "warn", "warn", "page"]);
  });
});

describe("coverageProbe", () => {
  let liquidity = 1_000n;
  const backed = { supplyEqualsCredited: true, hubHoldsSupplied: true, sharesEqualAssets: true, noDrawnShares: true, noDrawCap: true, singleBorrowSpoke: true, noLiquidityFee: true, noReinvestment: true, reserveFlags: true };
  const chain = fakeProvider({
    handlers: [
      on("getCapHeadroom", (args) => ({ poolShareBps: args[0] === fixtureMarkets[0]!.vaultToken ? 1_600n : 100n, poolShareMaxBps: 2_000n })),
      on("checkBacking", (args) => (args[0] === fixtureMarkets[1]!.vaultToken ? { ...backed, supplyEqualsCredited: false } : backed)),
      on("getTailCoverage", () => ({ funded: 250n, minimum: 200n, ratioBps: 9_000n, deficitOffset: OFFSET, offsetFunded: 50n })),
      on("firstLossReserveMinimum", () => 100n, OFFSET),
      on("liquidity", () => liquidity),
    ],
  });

  it("judges every market, loss-layer pair and pool, and M-28 over the hour", async () => {
    const probe = coverageProbe();
    const round = async (timestamp: number) => {
      const ctx = await contextOf(chain, { number: BigInt(timestamp), timestamp });
      const input = await probe.read(ctx);
      return Object.fromEntries(probe.evaluate(input, ctx.block).map((f) => [`${f.signal} ${f.subject}`, f.level]));
    };
    const key = tailKey(FIXTURE_HUB, FIXTURE_USDC);
    const pool = fixtureMarkets[0]!.pool.toLowerCase();
    expect(await round(1_000)).toMatchObject({
      "M-07 market:1:poolShare": "warn",
      "M-07 market:2:poolShare": "ok",
      "M-21 market:1:backing": "ok",
      "M-21 market:2:backing": "page",
      [`M-13 tail:${key}:reserve`]: "warn",
      [`M-13 tail:${key}:offset`]: "warn",
      [`M-14 tail:${key}:ratio`]: "page",
      [`M-28 pool:${pool}`]: "ok",
    });
    liquidity = 800n;
    expect((await round(2_000))[`M-28 pool:${pool}`]).toBe("warn");
    liquidity = 600n;
    expect((await round(3_000))[`M-28 pool:${pool}`]).toBe("page");
    expect((await round(4_700))[`M-28 pool:${pool}`]).toBe("warn"); // the 1,000 sample left the hour; 800 -> 600
  });
});
