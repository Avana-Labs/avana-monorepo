// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Hub-to-Hub credit lines: a CDP Spoke whose home Hub is another one drawing on a funding Hub's asset. Each line is
// the registry's cap joined with the Spoke's slice of the funding Hub asset (its draw) and that asset's price.

import { v } from "convex/values";
import { query } from "./_generated/server";
import { creditLineViews, loadWorld } from "./model.ts";

export const list = query({
  args: { chainId: v.optional(v.number()), hub: v.optional(v.string()) },
  handler: async (ctx, { chainId, hub }) => {
    const h = hub?.toLowerCase();
    return creditLineViews(await loadWorld(ctx), (l) => (chainId === undefined || l.chainId === chainId) && (h === undefined || l.fundingHub === h || l.homeHub === h));
  },
});
