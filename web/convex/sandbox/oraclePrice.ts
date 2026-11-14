import type { MutationCtx, QueryCtx } from "../_generated/server"
import { PRICE_INVALID_AFTER_MS, PRICE_MIN_CONFIDENCE } from "../prices"

/** Current server-owned token price shared by quote and execution paths. */
export async function validatedTokenPriceUsd(
  ctx: QueryCtx | MutationCtx,
  symbol: string,
  now = Date.now(),
): Promise<number | null> {
  const row = await ctx.db
    .query("tokenPrices")
    .withIndex("by_symbol", (q) => q.eq("symbol", symbol.toLowerCase()))
    .unique()
  if (
    !row ||
    !Number.isFinite(row.priceUsd) ||
    row.priceUsd <= 0 ||
    row.status === "invalid" ||
    now - row.updatedAt >= PRICE_INVALID_AFTER_MS ||
    (row.confidence != null && row.confidence < PRICE_MIN_CONFIDENCE)
  ) {
    return null
  }
  return row.priceUsd
}
