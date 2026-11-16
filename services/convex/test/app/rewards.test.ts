// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Reward points: quests awarded once from a wallet's first deposit, borrow, repay and pledge, tenure computed on read,
// and the fee slot summed with them.
import { convexTest } from "convex-test";
import { describe, expect, test } from "vitest";
import { api } from "../../convex/_generated/api";
import { awardPoints, awardQuestForLog, QUEST_OF_LOG, QUEST_POINTS, tenurePoints } from "../../convex/lib/rewards";
import { noteFirstSeen } from "../../convex/lib/membership";
import schema from "../../convex/schema";

const modules = import.meta.glob("../../convex/**/*.*s");
const WALLET = "0xAbC0000000000000000000000000000000000001";
const DAY = 86_400_000;

describe("tenure points", () => {
  test("100 for each full 30 days, nothing before the first period", () => {
    const at = (days: number) => tenurePoints(0, days * DAY);
    expect([at(0), at(29.9), at(30), at(59.9), at(60), at(365)]).toEqual([0, 0, 100, 100, 200, 1200]);
    expect(tenurePoints(10 * DAY, 5 * DAY)).toBe(0);
  });
});

describe("quest points", () => {
  test("every quest of a log has points, and the four quests are the app's", () => {
    for (const questId of Object.values(QUEST_OF_LOG)) expect(QUEST_POINTS[questId]).toBeGreaterThan(0);
    expect(Object.keys(QUEST_POINTS).sort()).toEqual(["first-borrow", "first-lend-deposit", "first-repay", "pledge-uniswap-v3-position"]);
  });

  test("a log completes its quest once, whichever log of the quest comes again", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await awardQuestForLog(ctx, WALLET, "AaveSpoke.Supply", 1_000);
      await awardQuestForLog(ctx, WALLET, "AaveSpoke.Supply", 2_000);
      await awardQuestForLog(ctx, WALLET, "AaveAdapter.Repaid", 3_000);
      await awardQuestForLog(ctx, WALLET, "AaveAdapter.RepaidWithCollateral", 4_000);
      await awardQuestForLog(ctx, WALLET, "AaveSpoke.Withdraw", 5_000);
      await awardQuestForLog(ctx, WALLET, "AaveAdapter.Borrowed", 0);
    });
    const [events, totals] = await t.run(async (ctx) => [await ctx.db.query("rewardEvents").collect(), await ctx.db.query("rewardTotals").collect()] as const);
    expect(events.map((e) => [e.key, e.points]).sort()).toEqual([["quest:first-lend-deposit", 40], ["quest:first-repay", 30]]);
    expect(totals).toHaveLength(1);
    expect(totals[0]).toMatchObject({ wallet: WALLET.toLowerCase(), questPoints: 70, feePoints: 0 });
    expect([...totals[0]!.questIds].sort()).toEqual(["first-lend-deposit", "first-repay"]);
  });

  test("awarding the same key twice, or no points, changes nothing", async () => {
    const t = convexTest(schema, modules);
    const results = await t.run(async (ctx) => [
      await awardPoints(ctx, { wallet: WALLET, kind: "fee", key: "fee:1:0xaa", points: 12, at: 1 }),
      await awardPoints(ctx, { wallet: WALLET, kind: "fee", key: "fee:1:0xaa", points: 12, at: 2 }),
      await awardPoints(ctx, { wallet: WALLET, kind: "fee", key: "fee:1:0xbb", points: 0, at: 3 }),
    ]);
    expect(results).toEqual([true, false, false]);
    expect(await t.run((ctx) => ctx.db.query("rewardTotals").collect())).toMatchObject([{ feePoints: 12, questPoints: 0 }]);
  });
});

describe("rewards summary", () => {
  test("is zero for a wallet with no activity, and rejects a malformed wallet", async () => {
    const t = convexTest(schema, modules);
    expect(await t.query(api.wallet.rewards.summary, { wallet: WALLET })).toEqual({ earnedPoints: 0, tenurePoints: 0, questPoints: 0, feePoints: 0, completedQuests: [] });
    await expect(t.query(api.wallet.rewards.summary, { wallet: "0x12" })).rejects.toThrow(/20-byte address/);
  });

  test("adds tenure, quest and fee points, with the completed quests", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await noteFirstSeen(ctx, WALLET, Date.now() - 65 * DAY, "onchain");
      await awardQuestForLog(ctx, WALLET, "AaveAdapter.Borrowed", 1_000);
      await awardPoints(ctx, { wallet: WALLET, kind: "fee", key: "fee:1:0xaa", points: 7, at: 2 });
    });
    expect(await t.query(api.wallet.rewards.summary, { wallet: WALLET.toLowerCase() })).toEqual({
      earnedPoints: 200 + 50 + 7,
      tenurePoints: 200,
      questPoints: 50,
      feePoints: 7,
      completedQuests: ["first-borrow"],
    });
  });
});
