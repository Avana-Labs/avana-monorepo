// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The identity a Lend detail page falls back on.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { loadWorld } from "../model.ts";
import { readSiloedMarket } from "../details.ts";

export const getMarket = query({ args: { slug: v.string() }, handler: async (ctx, { slug }) => readSiloedMarket(await loadWorld(ctx), "lend", slug) });
