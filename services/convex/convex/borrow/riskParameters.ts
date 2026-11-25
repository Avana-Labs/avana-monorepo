// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Risk parameters of a Borrow page: collateral parameters for a market, draw cap and price status for a reserve.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { loadWorld } from "../model.ts";
import { readRiskParameters } from "../details.ts";
import { borrowScope } from "./scope.ts";

export const getRiskParameters = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => {
    const w = await loadWorld(ctx);
    const scope = borrowScope(w, slug);
    return scope ? readRiskParameters(w, scope, slug) : null;
  },
});

export const getRiskParametersForSlugs = query({
  args: { slugs: v.array(v.string()) },
  handler: async (ctx, { slugs }) => {
    const w = await loadWorld(ctx);
    return slugs.flatMap((slug) => {
      const scope = borrowScope(w, slug);
      const p = scope ? readRiskParameters(w, scope, slug) : null;
      return p ? [p] : [];
    });
  },
});
