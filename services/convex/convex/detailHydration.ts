// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One query per detail page, batching the cards the page renders from the same scope rows. Hero series, quick
// stats and cashflow are separate queries because the app preloads them for other components.

import { v } from "convex/values";
import { query } from "./_generated/server";
import { readAddresses, readAllocationForAsset, readContent, readInterestRateModel, readLiquidationRisk, readPoolBorrowables, readRisk, readRiskParameters, readSiloedMarket } from "./details.ts";
import { readMarketSnapshot, readRecentTransactions, readSupplyBorrow } from "./markets.ts";
import { loadWorld } from "./model.ts";

const args = { slug: v.string() };

/** `/lend/markets/[slug]`: one Hub asset. */
export const getLendDetail = query({
  args,
  handler: async (ctx, { slug }) => {
    const w = await loadWorld(ctx);
    return {
      snapshot: await readMarketSnapshot(ctx, w, "lend", slug),
      transactions: await readRecentTransactions(ctx, w, "lend", slug),
      risk: readRisk(w, "lend", slug),
      content: await readContent(ctx, w, "lend", slug),
      riskParameters: readRiskParameters(w, "lend", slug),
      interestRateModel: readInterestRateModel(w, "lend", slug),
      siloedMarket: readSiloedMarket(w, "lend", slug),
      contractAddresses: (await readAddresses(ctx, w, "lend", slug)).map(({ slug: marketSlug, ...r }) => ({ marketSlug, ...r })),
      supplyBorrow: await readSupplyBorrow(ctx, w, "lend", slug),
    };
  },
});

/** `/borrow/pool/[slug]`: one collateral market. */
export const getBorrowPoolDetail = query({
  args,
  handler: async (ctx, { slug }) => {
    const w = await loadWorld(ctx);
    return {
      snapshot: await readMarketSnapshot(ctx, w, "pool", slug),
      transactions: await readRecentTransactions(ctx, w, "pool", slug),
      risk: readRisk(w, "pool", slug),
      content: await readContent(ctx, w, "pool", slug),
      riskParameters: readRiskParameters(w, "pool", slug),
      poolBorrowables: readPoolBorrowables(w, slug),
      liquidationRisk: await readLiquidationRisk(ctx, w, slug),
      siloedMarket: readSiloedMarket(w, "pool", slug),
      contractAddresses: (await readAddresses(ctx, w, "pool", slug)).map(({ slug: poolSlug, ...r }) => ({ poolSlug, ...r })),
    };
  },
});

/** `/borrow/assets/[slug]`: one CDP Spoke's debt reserve, with its Hub asset as context. */
export const getBorrowAssetDetail = query({
  args,
  handler: async (ctx, { slug }) => {
    const w = await loadWorld(ctx);
    const allocation = readAllocationForAsset(w, slug);
    return {
      snapshot: await readMarketSnapshot(ctx, w, "asset", slug),
      supplyBorrow: await readSupplyBorrow(ctx, w, "asset", slug),
      transactions: await readRecentTransactions(ctx, w, "asset", slug),
      allocation,
      allocationRiskParameters: allocation.map((a) => readRiskParameters(w, "pool", a.poolSlug)).filter((p) => p !== null),
      risk: readRisk(w, "asset", slug),
      content: await readContent(ctx, w, "asset", slug),
      riskParameters: readRiskParameters(w, "asset", slug),
      interestRateModel: readInterestRateModel(w, "asset", slug),
      siloedMarket: readSiloedMarket(w, "asset", slug),
      contractAddresses: (await readAddresses(ctx, w, "asset", slug)).map(({ slug: assetSlug, ...r }) => ({ assetSlug, ...r })),
    };
  },
});

