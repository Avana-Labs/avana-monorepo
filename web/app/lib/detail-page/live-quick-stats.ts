/**
 * Maps the canonical ids Convex `getQuickStats` emits onto each product's own stat ids.
 * Must stay client-safe (no `server-only`) — both server builders and the client
 * `QuickStatsGrid` import it.
 */
export type QuickStatsProduct = "borrow" | "lend" | "multiply"

export const QUICK_STAT_ALIASES: Record<QuickStatsProduct, Record<string, string[]>> = {
  // Borrow covers both pool and asset scopes (shared map).
  borrow: {
    supplied: ["supplied", "totalSupplied"],
    borrowed: ["borrowed", "totalBorrowed"],
    utilization: ["utilization"],
    supplyApy: ["supplyApy", "apr"],
    borrowApy: ["borrowApy"],
    available: ["available"],
  },
  lend: {
    supplyApy: ["supplyApy"],
    borrowApy: ["borrowApy"],
  },
  multiply: {
    supplyApy: ["supplyApy"],
    borrowApy: ["borrowApy"],
  },
}
