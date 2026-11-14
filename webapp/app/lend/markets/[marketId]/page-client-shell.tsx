"use client"

import type { LendMarketDetail } from "@/app/lib/lend-detail"
import { LendMarketDetailClient } from "./market-detail-client"

export function LendMarketDetailClientShell({ detail }: { detail: LendMarketDetail }) {
  return <LendMarketDetailClient detail={detail} />
}
