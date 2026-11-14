// SEED ONLY — imported by build-seed.ts. Not for UI code.
/**
 * Per-spoke borrowable asset seed rows.
 *
 * Mirrors what `listSpokeBorrowables()` produces at runtime (registry.ts walks
 * BORROW_SPOKES × BORROWABLE_ASSETS, filtering to (spoke, asset) pairs where
 * spoke.borrowableTokens[] includes the asset symbol, and derives capacity,
 * borrow APR, and utilization from FNV-1a-seeded per-market jitter). To keep
 * parity with the mock automatically we import that function here and reshape
 * each record into a `SeedBorrowAssetRow` at export time, rather than
 * re-implementing the derivation formulas.
 */

import { listSpokeBorrowables } from "@/app/lib/borrow-system/registry"
import type { SeedBorrowAssetRow, SeedTokenVisual } from "../build-seed"

function toDisplayVisual(visual: {
  symbol: string
  shortLabel: string
  bgClass: string
  textClass: string
  iconUrl?: string
}): SeedTokenVisual {
  return {
    symbol: visual.symbol,
    // BorrowAssetVisual.iconUrl is optional but the seed row shape requires a
    // string; every base borrowable asset in BORROWABLE_ASSETS has an icon in
    // the VISUALS map, so this fallback only guards the type.
    iconUrl: visual.iconUrl ?? "",
    shortLabel: visual.shortLabel,
    bgClass: visual.bgClass,
    textClass: visual.textClass,
  }
}

export const BORROW_ASSETS_SEED_ROWS: SeedBorrowAssetRow[] = listSpokeBorrowables().map((asset) => ({
  id: asset.id,
  spokeId: asset.spokeId,
  baseAssetId: asset.baseAssetId,
  name: asset.name,
  symbol: asset.symbol,
  subtitle: asset.subtitle,
  category: asset.category,
  contextLabel: asset.contextLabel,
  displayVisual: toDisplayVisual(asset.visual),
  baseBorrowAprPct: asset.borrowApr,
  // `availableUsd` in the registry is `roundUsd(totalCapacityUsd)`, and
  // `roundUsd` is idempotent — so `availableUsd === totalCapacityUsd` by
  // construction. Sourcing both from the same field preserves that identity.
  totalCapacityUsd: asset.availableUsd,
  utilizationPct: asset.utilization,
  totalBorrowedUsd: asset.totalBorrowedUsd,
  availableUsd: asset.availableUsd,
  marketIds: asset.marketIds,
}))
