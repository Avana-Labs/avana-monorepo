import "server-only"
import type { BorrowPoolRow, BorrowableAsset } from "@/app/lib/borrow-market-rows"
import { fetchBorrowPage } from "@/app/lib/data/providers/borrow"
import type { LendMarket } from "@/app/lib/lend-system/model"
import { emptyLendSystemState, mergeConvexLendSnapshots } from "@/app/lib/lend-system/market-hydration"
import { fetchLendMarketSnapshots } from "@/app/lib/lend-system/market-hydration-server"

/** What the header search lists: the same pools, borrowable assets and Lend markets as the Borrow and Lend pages. */
export type SearchIndex = {
  pools: BorrowPoolRow[]
  assets: BorrowableAsset[]
  lendMarkets: LendMarket[]
}

/**
 * The header search's data, read on the server from the same sources as the Borrow and Lend pages. The header sits
 * above the session providers (layout.tsx), so it cannot read the session state the pages use.
 */
export async function buildSearchIndex(): Promise<SearchIndex> {
  const [borrow, lendSnapshots] = await Promise.all([fetchBorrowPage(), fetchLendMarketSnapshots()])
  const lend = mergeConvexLendSnapshots(emptyLendSystemState("search"), lendSnapshots)
  return {
    pools: [...borrow.poolCatalog],
    assets: [...borrow.borrowableAssets],
    lendMarkets: Object.values(lend.markets),
  }
}
