// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Borrow pages are keyed by slug alone; a slug names either a collateral market (pool page) or a CDP debt reserve
// (asset page). Slugs are unique across both (metadata validation and the default slug forms keep them apart).

import type { World } from "../model.ts";

export function borrowScope(w: World, slug: string): "pool" | "asset" | null {
  if (w.markets.some((m) => m.slug === slug)) return "pool";
  if (w.reserves.some((r) => r.slug === slug)) return "asset";
  return null;
}
