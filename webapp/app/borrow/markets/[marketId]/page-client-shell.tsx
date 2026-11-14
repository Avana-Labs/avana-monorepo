"use client"

import type { PoolDetail } from "@/app/lib/borrow-detail"
import { PoolDetailClient } from "@/app/borrow/pool/[poolId]/pool-detail-client"

export function BorrowMarketDetailClientShell({ detail }: { detail: PoolDetail }) {
  return <PoolDetailClient detail={detail} />
}
