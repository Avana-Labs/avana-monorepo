// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The coverage probe on a scripted chain: M-13 (First-Loss Reserve and DAO deficit offset), M-14 (draw-cap coverage)
// and M-28 (pool liquidity) at their boundaries, a Uniswap v4 pool read through the PoolManager.

import { describe, expect, it } from "vitest";
import type { ServiceManifest } from "@avana/services-common";
import { FIXTURE_HUB, FIXTURE_USDC, fixtureMarkets } from "@avana/services-common/fixtures";
import { type Layer, coverageProbe, m13, m14 } from "../src/probes/coverage.ts";
import { encodePacked, keccak256, toHex } from "viem";
import { EMPTY_MANIFEST, contextOf, fakeProvider, fixtureSnapshot, on } from "./fakeChain.ts";

const RESERVE = "0x00000000000000000000000000000000000000c1";
const OFFSET = "0x00000000000000000000000000000000000000d0";
const layer = (o: Partial<Layer> = {}): Layer => ({ address: RESERVE, label: "stable USDC", funded: 300n, minimum: 200n, offset: false, ...o });

describe("coverage rules", () => {
  it("M-13 warns below 150 % of a reserve's minimum, pages below 100 %, and warns on an offset below its minimum", () => {
    expect([300n, 299n, 200n, 199n].map((funded) => m13(layer({ funded })))).toEqual(["ok", "warn", "warn", "page"]);
    expect(m13(layer({ minimum: 0n }))).toBeNull();
    expect([m13(layer({ offset: true, funded: 200n })), m13(layer({ offset: true, funded: 199n }))]).toEqual(["ok", "warn"]);
  });

  it("M-14 warns below 150 % of the required balance and pages below 100 %", () => {
    expect([1_500n, 1_499n, 1_000n, 999n].map((funded) => m14({ funded, required: 1_000n }))).toEqual(["ok", "warn", "warn", "page"]);
    expect(m14({ funded: 0n, required: 0n })).toBe("ok");
  });
});

const integration = (id: number, kind: string) => ({ integrationId: id, kind, riskModule: { address: "0x00000000000000000000000000000000000000a1" } });
const manifestWith = (o: Record<string, unknown> = {}) =>
  ({
    ...EMPTY_MANIFEST,
    avana: { ...EMPTY_MANIFEST.avana, integrations: [integration(1, "uniswap-v3"), integration(3, "uniswap-v4")] },
    coverage: {
      firstLossReserves: [{ address: RESERVE, hubLabel: "stable", symbol: "USDC" }],
      daoDeficitOffsets: [{ address: OFFSET, hubLabel: "stable", symbol: "USDC" }],
    },
    ...o,
  }) as unknown as ServiceManifest;

describe("coverageProbe", () => {
  let liquidity = 1_000n;
  const chain = fakeProvider({
    handlers: [
      on("fundedBalance", () => 250n, RESERVE),
      on("minimum", () => 200n, RESERVE),
      on("fundedBalance", () => 50n, OFFSET),
      on("minimum", () => 100n, OFFSET),
      on("liquidity", () => liquidity),
    ],
  });

  it("judges every loss layer, the covered Hub asset and the pool both markets share, and M-28 over the hour", async () => {
    const probe = coverageProbe();
    const round = async (timestamp: number) => {
      const ctx = await contextOf(chain, { number: BigInt(timestamp), timestamp }, manifestWith());
      const input = await probe.read(ctx);
      return Object.fromEntries(probe.evaluate(input, ctx.block).map((f) => [`${f.signal} ${f.subject}`, f.level]));
    };
    const pool = fixtureMarkets[0]!.pool.toLowerCase();
    const first = await round(1_000);
    expect(first).toMatchObject({
      [`M-13 layer:${RESERVE}`]: "warn",
      [`M-13 layer:${OFFSET}`]: "warn",
      // The fixture's First-Loss Reserve holds 200,000 USDC against 175,000 required: below 150 %.
      [`M-14 coverage:${FIXTURE_HUB}:${FIXTURE_USDC}`]: "warn",
      [`M-28 pool:${pool}`]: "ok",
    });
    expect(Object.keys(first).filter((k) => k.startsWith("M-28"))).toHaveLength(1);
    liquidity = 800n;
    expect((await round(2_000))[`M-28 pool:${pool}`]).toBe("warn");
    liquidity = 600n;
    expect((await round(3_000))[`M-28 pool:${pool}`]).toBe("page");
    expect((await round(4_700))[`M-28 pool:${pool}`]).toBe("warn"); // the 1,000 sample left the hour; 800 -> 600
  });
});

describe("coverageProbe on a Uniswap v4 pool", () => {
  const MANAGER = "0x000000000004444c5dc75cb358380d2e3de08a90";
  const POOL_ID = `0x${"7c".repeat(32)}` as const;
  const v4Market = { ...fixtureMarkets[0]!, marketId: "3", integrationId: 3, pool: POOL_ID, vaultToken: "0x00000000000000000000000000000000000000f3" } as (typeof fixtureMarkets)[number];
  // StateLibrary: the pool's state at keccak256(poolId . 6), liquidity in the low 128 bits of the fourth word.
  const LIQUIDITY_SLOT = toHex(BigInt(keccak256(encodePacked(["bytes32", "uint256"], [POOL_ID, 6n]))) + 3n, { size: 32 });
  let word = 0n;
  const chain = fakeProvider({
    snapshot: (b) => fixtureSnapshot(b, (s) => ({ ...s, markets: [...s.markets, v4Market] })),
    handlers: [on("fundedBalance", () => 0n), on("minimum", () => 0n), on("liquidity", () => 1_000n), on("extsload", (args) => (args[0] === LIQUIDITY_SLOT ? toHex(word, { size: 32 }) : undefined), MANAGER)],
  });
  const m28 = async (manifest: ServiceManifest, timestamp: number, probe = coverageProbe()) => {
    const ctx = await contextOf(chain, { number: BigInt(timestamp), timestamp }, manifest);
    return probe.evaluate(await probe.read(ctx), ctx.block).filter((f) => f.signal === "M-28" && f.subject === `pool:${POOL_ID}`);
  };

  it("reads the pool's liquidity through the PoolManager and keys the subject by PoolId", async () => {
    const probe = coverageProbe();
    const withManager = manifestWith({ uniswapV4: { poolManager: { address: MANAGER, startBlock: 1 } } });
    word = (5n << 200n) | 1_000n; // bits above 128 are not liquidity
    expect(await m28(withManager, 1_000, probe)).toMatchObject([{ kind: "condition", level: "ok", detail: { pool: POOL_ID, liquidity: "1000" } }]);
    word = 600n;
    expect(await m28(withManager, 2_000, probe)).toMatchObject([{ kind: "condition", level: "page" }]);
  });

  it("reports the pool unread when the manifest names no PoolManager", async () => {
    expect(await m28(manifestWith(), 1_000)).toMatchObject([{ kind: "unread" }]);
  });
});
