// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Parameters of a supply market: supply cap, reserve factor, credit line, coverage and status.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { loadWorld } from "../model.ts";
import { readRiskParameters } from "../details.ts";

export const getRiskParameters = query({ args: { slug: v.string() }, handler: async (ctx, { slug }) => readRiskParameters(await loadWorld(ctx), "lend", slug) });
