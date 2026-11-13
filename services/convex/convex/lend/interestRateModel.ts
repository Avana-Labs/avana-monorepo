// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The Hub asset's rate curve and current point.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { loadWorld } from "../model.ts";
import { readInterestRateModel } from "../details.ts";

export const getInterestRateModel = query({ args: { slug: v.string() }, handler: async (ctx, { slug }) => readInterestRateModel(await loadWorld(ctx), "lend", slug) });
