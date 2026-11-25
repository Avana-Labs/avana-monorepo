// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// About, history, FAQs and parameter changelog of a Borrow page.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { loadWorld } from "../model.ts";
import { readContent } from "../details.ts";
import { borrowScope } from "./scope.ts";

export const getContent = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => {
    const w = await loadWorld(ctx);
    const scope = borrowScope(w, slug);
    return scope ? readContent(ctx, w, scope, slug) : null;
  },
});
