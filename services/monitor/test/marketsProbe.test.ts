// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// M-36 (band edge of a Custom range market), M-37 (depeg above 1 % on a Stable or Correlated pair, freeze as the
// response) and M-35 (keeper wallets and the top-up wallet against the 11-fund-keepers refill rule).

import { describe, expect, it } from "vitest";
import type { ServiceManifest } from "@avana/services-common";
import { fixtureMarkets } from "@avana/services-common/fixtures";
import { toHex } from "viem";
import { bandEdgeBps, decodeV4Slot0, deviationPpm, m36, m37, marketsProbe } from "../src/probes/markets.ts";
import { m35Keeper, walletLimits, walletsProbe } from "../src/probes/wallets.ts";
import { EMPTY_MANIFEST, contextOf, fakeProvider, fixtureSnapshot, on } from "./fakeChain.ts";

const Q96 = 2n ** 96n;

describe("band edge", () => {
  it("measures the distance to the nearer edge in bps of the band's width, negative outside", () => {
    expect(bandEdgeBps(0, -100, 100)).toBe(5_000);
    expect(bandEdgeBps(80, -100, 100)).toBe(1_000);
    expect(bandEdgeBps(101, -100, 100)).toBeLessThan(0);
    expect([m36(1_001), m36(1_000), m36(0), m36(-1)]).toEqual(["ok", "warn", "warn", "page"]);
  });
});

describe("depeg", () => {
  it("measures the pool against the fair price and pages only while the market is open", () => {
    // sqrt(1.0201) = 1.01: a 2.01 % price deviation.
    expect(deviationPpm(101n * Q96, 100n * Q96)).toBe(20_100n);
    expect(deviationPpm(Q96, Q96)).toBe(0n);
    expect(m37({ ppm: 10_000n, lowToken: null }, false)).toBe("ok");
    expect(m37({ ppm: 10_001n, lowToken: null }, false)).toBe("page");
    expect(m37({ ppm: 10_001n, lowToken: null }, true)).toBe("warn");
    expect(m37({ ppm: 0n, lowToken: 1 }, false)).toBe("page");
  });

  it("decodes a packed Uniswap v4 slot0, a negative tick included", () => {
    const word = toHex((BigInt(0x1000000 - 5) << 160n) | 12_345n, { size: 32 });
    expect(decodeV4Slot0(word)).toEqual({ sqrtPriceX96: 12_345n, tick: -5 });
  });
});

describe("marketsProbe", () => {
  const RM = "0x00000000000000000000000000000000000000a1";
  const manifest = { ...EMPTY_MANIFEST, avana: { ...EMPTY_MANIFEST.avana, integrations: [{ integrationId: 1, kind: "uniswap-v3", riskModule: { address: RM } }] } } as unknown as ServiceManifest;
  const run = async (o: { tick: number; poolSqrt: bigint; kind: number; price1?: bigint; frozen?: boolean }) => {
    const p = fakeProvider({
      snapshot: (b) => fixtureSnapshot(b, (s) => ({ ...s, markets: fixtureMarkets.map((m) => ({ ...m, frozen: o.frozen ?? false })) })),
      handlers: [on("getSpoke", () => ({ hub: RM, kind: o.kind }), RM), on("getPrices", () => [100_000_000n, o.price1 ?? 100_000_000n, Q96]), on("slot0", () => [o.poolSqrt, o.tick])],
    });
    const probe = marketsProbe();
    const ctx = await contextOf(p, { number: 1n, timestamp: 12 }, manifest);
    return Object.fromEntries(probe.evaluate(await probe.read(ctx), ctx.block).map((f) => [`${f.signal} ${f.subject}`, [f.level, f.detail.response]]));
  };

  it("watches the Custom range market's band and both markets' peg on a Stable pair", async () => {
    const fs = await run({ tick: 95, poolSqrt: (Q96 * 1_006n) / 1_000n, kind: 1 });
    // Market 2 is Custom range [-100, 100]; market 1 is Full range, so it has no band alert.
    expect(fs["M-36 market:2:band"]?.[0]).toBe("warn");
    expect(fs["M-36 market:1:band"]).toBeUndefined();
    expect(fs["M-37 market:1:depeg"]).toEqual(["page", "freeze the market's vault-token reserve on its Spoke (depeg = freeze)"]);
  });

  it("warns once the depegged market is frozen, flags a stable token below $0.99, and skips a Volatile pair", async () => {
    expect((await run({ tick: 0, poolSqrt: Q96, kind: 1, price1: 98_000_000n, frozen: true }))["M-37 market:1:depeg"]?.[0]).toBe("warn");
    const volatile = await run({ tick: 0, poolSqrt: Q96 * 2n, kind: 3 });
    expect(Object.keys(volatile).filter((k) => k.startsWith("M-37"))).toEqual([]);
  });
});

describe("walletsProbe", () => {
  const KEEPER = "0x00000000000000000000000000000000000000b1";
  const TOPUP = "0x00000000000000000000000000000000000000b2";
  const rule = { wallet: TOPUP, minBalanceWei: "3000", targetBalanceWei: "10000" };
  const manifest = { ...EMPTY_MANIFEST, roles: { keepers: [KEEPER], keeperTopUp: rule } } as unknown as ServiceManifest;

  it("takes the limits from the refill rule unless overridden", () => {
    expect(walletLimits(rule, { warnWei: null, pageWei: null })).toEqual({ warnWei: 3_000n, pageWei: 1_000n, targetWei: 10_000n });
    expect(walletLimits(null, { warnWei: 5n, pageWei: 2n })).toEqual({ warnWei: 5n, pageWei: 2n, targetWei: 0n });
    expect(walletLimits(null, { warnWei: null, pageWei: null })).toBeNull();
    expect([2_999n, 999n, 3_000n].map((b) => m35Keeper(b, { warnWei: 3_000n, pageWei: 1_000n }))).toEqual(["warn", "page", "ok"]);
  });

  it("judges each keeper wallet and the top-up wallet against one full refill", async () => {
    const p = fakeProvider({ balances: new Map([[KEEPER, 500n], [TOPUP, 9_999n]]) });
    const probe = walletsProbe({ warnWei: null, pageWei: null, extra: [] });
    const ctx = await contextOf(p, { number: 1n, timestamp: 12 }, manifest);
    const fs = probe.evaluate(await probe.read(ctx), ctx.block);
    expect(fs.map((f) => [f.subject, f.level])).toEqual([
      [`keeperWallet:${KEEPER}`, "page"],
      [`topUpWallet:${TOPUP}`, "warn"],
    ]);
    expect(fs[0]!.detail).toMatchObject({ topUpWallet: TOPUP, action: "run step 11-fund-keepers" });
  });
});
