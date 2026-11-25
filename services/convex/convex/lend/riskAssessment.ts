// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A supply market has no borrower premium, so the premium card stays hidden (null).

import { v } from "convex/values";
import { query } from "../_generated/server";
import { loadWorld } from "../model.ts";
import { readRisk } from "../details.ts";

export const getRisk = query({ args: { slug: v.string() }, handler: async (ctx, { slug }) => readRisk(await loadWorld(ctx), "lend", slug) });
