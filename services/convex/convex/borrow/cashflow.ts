// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Interest cashflow of a Borrow asset page (this Spoke's draw). A pool's cashflow needs per-market interest
// history, which the market debt series gives once it has a year of samples; until then it is empty.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { loadWorld } from "../model.ts";
import { readCashflow } from "../details.ts";

export const getBreakdownForAsset = query({ args: { slug: v.string() }, handler: async (ctx, { slug }) => readCashflow(ctx, await loadWorld(ctx), "asset", slug) });

export const getBreakdownForPool = query({ args: { slug: v.string() }, handler: async () => null });
