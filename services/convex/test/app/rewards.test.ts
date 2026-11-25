// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Reward points: quests awarded once from a wallet's first deposit, borrow, repay and pledge, tenure computed on read,
// and the fee slot summed with them.
import { convexTest } from "convex-test";
import { fixtureHubAsset } from "@avana/services-common/fixtures";
import { describe, expect, test } from "vitest";
import { api } from "../../convex/_generated/api";
import { addSupplyVolume, awardPoints, awardQuestForIntent, awardQuestForLog, QUEST_OF_INTENT_KIND, QUEST_OF_LOG, QUEST_POINTS, supplyUsdOfLog, tenurePoints } from "../../convex/lib/rewards";
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
  test("every quest of a log or an intent has points, and the five action quests are the app's", () => {
    for (const questId of [...Object.values(QUEST_OF_LOG), ...Object.values(QUEST_OF_INTENT_KIND)]) expect(QUEST_POINTS[questId]).toBeGreaterThan(0);
    expect(Object.keys(QUEST_POINTS).sort()).toEqual(["first-borrow", "first-lend-deposit", "first-repay", "pledge-uniswap-v3-position", "supply-500-lend"]);
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
    expect(await t.query(api.wallet.rewards.summary, { wallet: WALLET })).toMatchObject({ earnedPoints: 0, tenurePoints: 0, questPoints: 0, feePoints: 0, completedQuests: [], historyChecked: true });
    await expect(t.query(api.wallet.rewards.summary, { wallet: "0x12" })).rejects.toThrow(/20-byte address/);
  });

  test("adds tenure, quest and fee points, with the completed quests", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await noteFirstSeen(ctx, WALLET, Date.now() - 65 * DAY, "onchain");
      await awardQuestForLog(ctx, WALLET, "AaveAdapter.Borrowed", 1_000);
      await awardPoints(ctx, { wallet: WALLET, kind: "fee", key: "fee:1:0xaa", points: 7, at: 2 });
    });
    expect(await t.query(api.wallet.rewards.summary, { wallet: WALLET.toLowerCase() })).toMatchObject({
      earnedPoints: 200 + 50 + 7,
      tenurePoints: 200,
      questPoints: 50,
      feePoints: 7,
      completedQuests: ["first-borrow"],
      historyChecked: true,
    });
  });
});

const asset = { ...fixtureHubAsset, slug: "usdc", updatedAt: 0, decimals: 6, priceUsd8: "100000000" };
const assetKey = `${asset.chainId}:${asset.hub}:${asset.assetId}`;
const supplyLog = (units: string) => ({ kind: "AaveSpoke.Supply", hubAssetKey: assetKey, args: { suppliedAmount: units } });

describe("intent and volume quests", () => {
  test("a confirmed transaction completes the quest of its kind once, together with the log of the same action", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await awardQuestForIntent(ctx, WALLET, "borrow", 1_000);
      await awardQuestForIntent(ctx, WALLET, "repayWithCollateral", 2_000);
      await awardQuestForIntent(ctx, WALLET, "swap", 3_000);
      await awardQuestForLog(ctx, WALLET, "AaveAdapter.Borrowed", 4_000);
    });
    const totals = await t.run((ctx) => ctx.db.query("rewardTotals").collect());
    expect(totals[0]).toMatchObject({ questPoints: 80 });
    expect([...totals[0]!.questIds].sort()).toEqual(["first-borrow", "first-repay"]);
  });

  test("values a supply at the Hub asset's price, and 0 for another log, an unknown asset or a bad amount", async () => {
    const t = convexTest(schema, modules);
    const values = await t.run(async (ctx) => {
      await ctx.db.insert("hubAssets", { ...asset, lendReserves: [...asset.lendReserves] });
      return [
        await supplyUsdOfLog(ctx, supplyLog("250000000")),
        await supplyUsdOfLog(ctx, { ...supplyLog("1"), kind: "AaveSpoke.Withdraw" }),
        await supplyUsdOfLog(ctx, { ...supplyLog("1"), hubAssetKey: `${asset.chainId}:${asset.hub}:99999` }),
        await supplyUsdOfLog(ctx, supplyLog("abc")),
      ];
    });
    expect(values).toEqual([250, 0, 0, 0]);
  });

  test("the volume quest is awarded once the supplied total reaches $500, and only once", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      await addSupplyVolume(ctx, WALLET, 300, 1_000);
      await addSupplyVolume(ctx, WALLET, 0, 1_500);
    });
    expect((await t.query(api.wallet.rewards.summary, { wallet: WALLET })).completedQuests).toEqual([]);
    await t.run(async (ctx) => {
      await addSupplyVolume(ctx, WALLET, 200, 2_000);
      await addSupplyVolume(ctx, WALLET, 900, 3_000);
    });
    const totals = await t.run((ctx) => ctx.db.query("rewardTotals").collect());
    expect(totals).toHaveLength(1);
    expect(totals[0]).toMatchObject({ supplyUsd: 1400, questPoints: 100, questIds: ["supply-500-lend"] });
  });
});
