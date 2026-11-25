// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Contract address cards of the detail pages, from the scope rows and the deployment's explorer.

import { v } from "convex/values";
import { query } from "./_generated/server";
import { readAddresses } from "./details.ts";
import { loadWorld } from "./model.ts";

export const listPoolAddresses = query({
  args: { poolSlug: v.string() },
  handler: async (ctx, { poolSlug }) => (await readAddresses(ctx, await loadWorld(ctx), "pool", poolSlug)).map(({ slug, ...r }) => ({ poolSlug: slug, ...r })),
});

export const listAssetAddresses = query({
  args: { assetSlug: v.string() },
  handler: async (ctx, { assetSlug }) => (await readAddresses(ctx, await loadWorld(ctx), "asset", assetSlug)).map(({ slug, ...r }) => ({ assetSlug: slug, ...r })),
});

export const listLendAddresses = query({
  args: { marketSlug: v.string() },
  handler: async (ctx, { marketSlug }) => (await readAddresses(ctx, await loadWorld(ctx), "lend", marketSlug)).map(({ slug, ...r }) => ({ marketSlug: slug, ...r })),
});
