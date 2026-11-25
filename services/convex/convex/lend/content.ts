// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// About, history, FAQs and parameter changelog of a Lend page.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { loadWorld } from "../model.ts";
import { readContent } from "../details.ts";

export const getContent = query({ args: { slug: v.string() }, handler: async (ctx, { slug }) => readContent(ctx, await loadWorld(ctx), "lend", slug) });
