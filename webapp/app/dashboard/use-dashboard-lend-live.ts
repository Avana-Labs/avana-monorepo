"use client"

import { useEffect, useState } from "react"
import type { PortfolioLendTabData } from "@/app/lib/data/providers/portfolio/types"
import type { useLendSession } from "@/app/lib/lend-system/use-lend-session"

type LendSession = ReturnType<typeof useLendSession>

export function useDashboardLendLive(walletId: string, lendSession: LendSession) {
  const [portfolioLend, setPortfolioLend] = useState<PortfolioLendTabData | null>(null)

  useEffect(() => {
    if (!walletId) {
      setPortfolioLend(null)
      return
    }

    let cancelled = false

    void lendSession.readAdapter
      .readPortfolioLend(walletId)
      .then((next) => {
        if (!cancelled) setPortfolioLend(next)
      })
      .catch(() => {
        if (!cancelled) setPortfolioLend(null)
      })

    return () => {
      cancelled = true
    }
  }, [lendSession.readAdapter, lendSession.state, lendSession.transactionHistory, walletId])

  return portfolioLend
}
