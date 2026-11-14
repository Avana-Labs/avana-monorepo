"use client"

/**
 * A wallet's balances by product (services/convex `wallet.productBalances.listForWallet`, a public
 * query keyed by wallet). services/convex answers empty buckets until the app reads balances live
 * over RPC. Returns undefined while the query is loading (Convex convention).
 */

import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import type { UserAssetBalance } from "./contracts"

/**
 * Per-token cost basis of the wallet's holdings, keyed by lowercased assetId. No source exists yet
 * (it needs the indexer's per-wallet history), so it is always empty and the P/L shows as unavailable.
 */
export function useConvexClaimBasis(_walletId: string | null | undefined): Record<string, number> | undefined {
  return EMPTY_BASIS
}

const EMPTY_BASIS: Record<string, number> = {}

/** "Member since" and boost of the Wallet Overview tiles: no source yet, so both are null. */
export function useConvexWalletOnboardingSummary(
  _walletId: string | null | undefined,
): { sinceMs: number | null; boost: number | null } | undefined {
  return NO_SUMMARY
}

const NO_SUMMARY = { sinceMs: null, boost: null }

export function useConvexProductWalletBalances(walletId: string | null | undefined): UserAssetBalance[] | undefined {
  const buckets = useQuery(
    api.wallet.productBalances.listForWallet,
    walletId ? { wallet: walletId } : "skip",
  )
  if (!buckets) return buckets === undefined ? undefined : []
  const resolvedWalletId = walletId ?? ""

  const rows: UserAssetBalance[] = []
  for (const row of buckets.liquid) {
    rows.push({
      id: `${resolvedWalletId}:${row.assetId}:liquid`,
      walletId: resolvedWalletId,
      assetId: row.assetId,
      amount: row.amount,
      valueUsd: row.valueUsd,
      sourceType: "wallet",
    })
  }
  for (const row of buckets.lend) {
    rows.push({
      id: `${resolvedWalletId}:${row.marketId}:lend:${row.state}`,
      walletId: resolvedWalletId,
      assetId: row.assetId,
      amount: row.amount,
      valueUsd: row.valueUsd,
      sourceType: row.state === "available" ? "lend_available" : "lend_deposited",
      sourcePositionId: row.marketId,
    })
  }
  for (const row of buckets.borrow) {
    rows.push({
      id: `${resolvedWalletId}:${row.marketId ?? row.assetId ?? row.symbol}:borrow:${row.state}`,
      walletId: resolvedWalletId,
      assetId: row.poolId ?? row.assetId ?? row.marketId ?? row.symbol.toLowerCase(),
      amount: row.amount,
      valueUsd: row.state === "debt" ? -row.valueUsd : row.valueUsd,
      symbol: row.symbol,
      isLpToken: row.state === "poolAvailable" || row.state === "collateral",
      unitPriceUsd: row.unitPriceUsd,
      ltvPct: row.ltvPct,
      sourceType:
        row.state === "poolAvailable"
          ? "borrow_collateral_unpledged"
          : row.state === "collateral"
            ? "borrow_collateral_pledged"
            : row.state === "debt"
              ? "borrow_debt"
              : "borrow_claimable",
      sourcePositionId: row.marketId,
    })
  }
  return rows
}
