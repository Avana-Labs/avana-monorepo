/** Decode dynamic route params for spoke asset ids (e.g. `uni-v2%3Adai` → `uni-v2:dai`). */
export function normalizeBorrowAssetRouteId(raw: string): string {
  try {
    return decodeURIComponent(raw)
  } catch {
    return raw
  }
}

/** Canonical href for a borrowable asset detail page. */
export function borrowAssetDetailPath(assetId: string): string {
  return `/borrow/assets/${encodeURIComponent(assetId)}`
}

/** Decode dynamic route params for market ids (reserved for future encoded ids). */
export function normalizeBorrowMarketRouteId(raw: string): string {
  try {
    return decodeURIComponent(raw)
  } catch {
    return raw
  }
}

/** Canonical href for a collateral market detail page. */
export function borrowMarketDetailPath(marketId: string): string {
  return `/borrow/markets/${encodeURIComponent(marketId)}`
}
