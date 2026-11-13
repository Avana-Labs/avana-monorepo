// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// "Assets you can borrow" on a pool page, at the market's own rate.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { loadWorld } from "../model.ts";
import { readPoolBorrowables } from "../details.ts";

export const getPoolBorrowables = query({ args: { poolSlug: v.string() }, handler: async (ctx, { poolSlug }) => readPoolBorrowables(await loadWorld(ctx), poolSlug) });
