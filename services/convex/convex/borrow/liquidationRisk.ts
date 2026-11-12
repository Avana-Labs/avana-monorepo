// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Liquidation activity of a collateral market.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { loadWorld } from "../model.ts";
import { readLiquidationRisk } from "../details.ts";

export const getLiquidationRisk = query({ args: { slug: v.string() }, handler: async (ctx, { slug }) => readLiquidationRisk(ctx, await loadWorld(ctx), slug) });
