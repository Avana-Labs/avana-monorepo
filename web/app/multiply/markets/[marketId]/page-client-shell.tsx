"use client"

import type { MultiplyMarketDetail } from "@/app/lib/multiply-detail"
import { MarketDetailClient } from "./market-detail-client"

export function MultiplyMarketDetailClientShell({ detail }: { detail: MultiplyMarketDetail }) {
  return <MarketDetailClient detail={detail} />
}
