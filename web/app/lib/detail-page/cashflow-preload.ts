import "server-only"
import { preloadQuery } from "convex/nextjs"
import type { Preloaded } from "convex/react"
import { api } from "@/convex/_generated/api"

/**
 * Server-side cashflow preload. The page reads it with `readPreloadedCashflow` and merges it
 * into `detail` on the server; the token is not passed to client components (it would
 * re-serialize the result into the RSC payload). All four product queries share the `{ slug }` args and
 * return shape, so the pool query's `Preloaded` type stands in for all of them. `null` when
 * no deployment URL is configured.
 */
type CashflowScope = "asset" | "pool" | "lend" | "multiply"
export type CashflowPreload = Preloaded<typeof api.borrow.cashflow.getBreakdownForPool>

export async function preloadDetailCashflow(scope: CashflowScope, slug: string): Promise<CashflowPreload | null> {
  const url = process.env.NEXT_PUBLIC_CONVEX_URL
  if (!url || !/^https?:\/\//.test(url)) return null
  try {
    switch (scope) {
      case "pool":
        return await preloadQuery(api.borrow.cashflow.getBreakdownForPool, { slug })
      case "asset":
        return (await preloadQuery(api.borrow.cashflow.getBreakdownForAsset, { slug })) as CashflowPreload
      case "lend":
        return (await preloadQuery(api.lend.cashflow.getBreakdown, { slug })) as CashflowPreload
      case "multiply":
        return (await preloadQuery(api.multiply.cashflow.getBreakdown, { slug })) as CashflowPreload
    }
  } catch {
    return null
  }
}
