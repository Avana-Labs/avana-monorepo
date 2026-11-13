// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The premium card of a pool page: the market's collateral risk premium.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { loadWorld } from "../model.ts";
import { readRisk } from "../details.ts";

export const getRisk = query({ args: { slug: v.string() }, handler: async (ctx, { slug }) => readRisk(await loadWorld(ctx), "pool", slug) });
