// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Interest paid on the Hub asset over 12 months, split between lenders and the Hub.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { loadWorld } from "../model.ts";
import { readCashflow } from "../details.ts";

export const getBreakdown = query({ args: { slug: v.string() }, handler: async (ctx, { slug }) => readCashflow(ctx, await loadWorld(ctx), "lend", slug) });
