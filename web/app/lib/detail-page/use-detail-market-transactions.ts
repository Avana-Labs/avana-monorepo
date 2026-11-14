"use client"

import * as React from "react"
import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import type { DetailTransactionRow } from "@/app/lib/detail-page/transaction-history"
import { mergeTransactionRows } from "@/app/lib/detail-page/transaction-history"

type Scope = "asset" | "pool" | "lend"

type ConvexDetailTx = {
  id: string
  at: string
  kind: string
  amountLabel: string
  amountUsd?: number
  tokenAmountLabel?: string
  token0AmountLabel?: string
  token1AmountLabel?: string
  tokenSymbol?: string
  tokenSymbolSecondary?: string
  counterpartyLabel?: string
  walletLabel?: string
  txHashShort: string
  source?: "sandbox" | "seed"
}

export function useDetailMarketTransactions({
  scope,
  slug,
  seedRows,
  sessionRows = [],
  limit = 25,
  mapConvexRow,
}: {
  scope: Scope
  slug: string | undefined
  seedRows: DetailTransactionRow[]
  sessionRows?: DetailTransactionRow[]
  limit?: number
  mapConvexRow: (row: ConvexDetailTx) => DetailTransactionRow
}) {
  const convexRows = useQuery(api.markets.getRecentTransactions, slug ? { scope, slug, limit } : "skip")

  return React.useMemo(() => {
    if (convexRows === undefined) {
      return mergeTransactionRows(sessionRows, [], seedRows, limit)
    }
    // The query already returns all users' sandbox activity when it exists and
    // seeded walletEvents only as a fallback, so map whatever it chose.
    const fromConvex = convexRows.map(mapConvexRow)
    if (fromConvex.length > 0) {
      return mergeTransactionRows(sessionRows, fromConvex, [], limit)
    }
    return mergeTransactionRows(sessionRows, [], seedRows, limit)
  }, [convexRows, limit, mapConvexRow, seedRows, sessionRows])
}
