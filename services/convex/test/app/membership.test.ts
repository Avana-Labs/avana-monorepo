// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// "Member since": the earliest first sign of a wallet, from the stored row, the recorded logs, the intents and the
// profile; no sign means null, never an invented date.
import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../../convex/_generated/api";
import { noteFirstSeen } from "../../convex/lib/membership";
import schema from "../../convex/schema";

const modules = import.meta.glob("../../convex/**/*.*s");
const WALLET = "0xAbC0000000000000000000000000000000000001";
const LOWER = WALLET.toLowerCase();
const HASH = `0x${"00".repeat(32)}`;

function log(wallet: string, at: number, n: number) {
  return {
    key: `1:${HASH}:${n}`,
    chainId: 1,
    kind: "AaveAdapter.UserProxyCreated",
    blockNumber: "100",
    blockHash: HASH,
    txHash: HASH,
    logIndex: n,
    address: `0x${"11".repeat(20)}`,
    at,
    args: {},
    wallet,
  };
}

describe("wallet membership", () => {
  test("is null for a wallet with no sign of activity", async () => {
    const t = convexTest(schema, modules);
    expect(
      await t.query(api.wallet.membership.get, { wallet: WALLET }),
    ).toBeNull();
  });

  test("rejects a malformed wallet", async () => {
    const t = convexTest(schema, modules);
    await expect(
      t.query(api.wallet.membership.get, { wallet: "0x12" }),
    ).rejects.toThrow(/20-byte address/);
  });

  test("a created profile is the member-since time", async () => {
    const t = convexTest(schema, modules);
    await t
      .withIdentity({ subject: WALLET })
      .mutation(api.wallet.profiles.savePreferences, {
        preferences: { language: "ES" },
      });
    const got = await t.query(api.wallet.membership.get, { wallet: WALLET });
    expect(got).toMatchObject({ source: "profile", discountBps: 0 });
    expect(got!.sinceMs).toBeGreaterThan(0);
    const row = await t.run((ctx) => ctx.db.query("memberships").collect());
    expect(row).toMatchObject([
      { wallet: LOWER, source: "profile", firstSeenAt: got!.sinceMs },
    ]);
  });

  test("an earlier on-chain log wins over a later profile, and the match is case-insensitive", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await ctx.db.insert("ingestedLogs", log(LOWER, 1_000, 0));
      await ctx.db.insert("walletProfiles", {
        wallet: LOWER,
        createdAt: 5_000,
        updatedAt: 5_000,
      });
    });
    expect(
      await t.query(api.wallet.membership.get, { wallet: WALLET }),
    ).toEqual({ sinceMs: 1_000, source: "onchain", discountBps: 3 });
  });

  test("the stored row survives after the log it came from is pruned", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await noteFirstSeen(ctx, WALLET, 2_000, "onchain");
    });
    expect(
      await t.query(api.wallet.membership.get, { wallet: WALLET }),
    ).toEqual({ sinceMs: 2_000, source: "onchain", discountBps: 3 });
  });

  test("keeps the earliest time and ignores a missing time", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await noteFirstSeen(ctx, WALLET, 3_000, "profile");
      await noteFirstSeen(ctx, WALLET, 4_000, "onchain");
      await noteFirstSeen(ctx, WALLET, 0, "onchain");
      await noteFirstSeen(ctx, WALLET, Number.NaN, "onchain");
      await noteFirstSeen(ctx, WALLET, 2_500, "intent");
    });
    const rows = await t.run((ctx) => ctx.db.query("memberships").collect());
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ firstSeenAt: 2_500, source: "intent" });
  });

  test("the discount follows tenure: 0 for a new member, 2 bps at 90 days", async () => {
    const t = convexTest(schema, modules);
    const DAY = 86_400_000;
    await t.run(async (ctx) => {
      await noteFirstSeen(ctx, WALLET, Date.now() - 91 * DAY, "onchain");
    });
    expect(await t.query(api.wallet.membership.get, { wallet: WALLET })).toMatchObject({ discountBps: 2 });
    const other = "0xAbC0000000000000000000000000000000000002";
    await t.run(async (ctx) => {
      await noteFirstSeen(ctx, other, Date.now() - DAY, "onchain");
    });
    expect(await t.query(api.wallet.membership.get, { wallet: other })).toMatchObject({ discountBps: 0 });
  });
});
