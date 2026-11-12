// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Borrow asset page allocation: this CDP Spoke's owed amount split by the collateral market that backs it.

import { v } from "convex/values";
import { query } from "./_generated/server";
import { readAllocationForAsset } from "./details.ts";
import { loadWorld } from "./model.ts";

export const getForAsset = query({ args: { slug: v.string() }, handler: async (ctx, { slug }) => readAllocationForAsset(await loadWorld(ctx), slug) });
