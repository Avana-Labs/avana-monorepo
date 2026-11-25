"use client"

import { useEffect, useState } from "react"
import type { PortfolioBorrowTabData } from "@/app/lib/data/providers/portfolio"
import type { useBorrowSession } from "@/app/lib/borrow-system/use-borrow-session"

type BorrowSession = ReturnType<typeof useBorrowSession>

export function useDashboardBorrowLive(walletId: string, borrowSession: BorrowSession) {
  const [portfolioBorrow, setPortfolioBorrow] = useState<PortfolioBorrowTabData | null>(null)

  useEffect(() => {
    if (!walletId) {
      setPortfolioBorrow(null)
      return
    }

    let cancelled = false

    void borrowSession.readAdapter
      .readPortfolioBorrow(walletId)
      .then((next) => {
        if (!cancelled) {
          setPortfolioBorrow(next)
        }
      })
      .catch(() => {
        if (!cancelled) {
          setPortfolioBorrow(null)
        }
      })

    return () => {
      cancelled = true
    }
  }, [borrowSession.readAdapter, borrowSession.state, borrowSession.transactionHistory, walletId])

  return portfolioBorrow
}
