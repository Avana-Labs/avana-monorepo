// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The app overlays live liquidity deltas on its market rows. Rows are read from the chain every 30 s, so there is no
// delta to overlay: the list is always empty.

import { query } from "./_generated/server";

export const listDeltaSnapshot = query({
  args: {},
  handler: async (): Promise<{ marketSlug: string; borrowedDeltaUsd: number; suppliedDeltaUsd: number; updatedAt: number }[]> => [],
});
