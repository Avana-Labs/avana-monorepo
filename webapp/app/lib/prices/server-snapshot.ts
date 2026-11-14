import "server-only"
import { api } from "@/convex/_generated/api"
import { publicConvexClient } from "@/app/lib/convex/server-client"
import { reportServerFetchFailure } from "@/app/lib/detail-page/report-server-fetch-failure"
import { validatedConvexPriceMap } from "./validated-convex-price"

export async function fetchTokenPrices(): Promise<Record<string, number> | null> {
  const client = publicConvexClient()
  if (!client) return null
  try {
    const snapshot = await client.query(api.prices.getPriceSnapshot, {})
    const rows = snapshot?.prices
    if (!rows || rows.length === 0) return null
    const map = validatedConvexPriceMap(rows)
    if (Object.keys(map).length === 0) return null
    return map
  } catch (error) {
    reportServerFetchFailure("fetchTokenPrices", error)
    return null
  }
}
