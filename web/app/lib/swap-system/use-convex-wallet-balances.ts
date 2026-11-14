"use client"

/**
 * Convex-backed replacement for DEMO_SWAP_BALANCES. Any component currently
 * consuming UserAssetBalance[] via getUserSwapBalances(walletId) can migrate to
 * this hook — the shape matches app/lib/swap-system/contracts.ts UserAssetBalance
 * exactly. Returns undefined while the query is loading (Convex convention);
 * returns [] when authenticated but no balances yet (fresh dev wallet).
 *
 * Wallet-scoped + gated on the authed identity (Convex requireSandboxWallet),
 * so this cannot leak another wallet's holdings.
 */

import { useMemo } from "react"
import { useQuery } from "convex/react"
import { useAuthedQueryArgs } from "@/app/lib/convex/use-authed-query-args"
import { api } from "@/convex/_generated/api"
import type { UserAssetBalance } from "./contracts"

/**
 * Per-token cost basis from onboarding: the USD price each free starter token was
 * granted at (`sandboxProfiles.basketSnapshot[].priceUsdAtClaim`), keyed by
 * lowercased assetId. The wallet P/L = current live value − amount × this basis,
 * so it reflects how much the granted capital has moved since the claim moment.
 * `undefined` while loading; `{}` when the wallet has no recorded basket.
 */
export function useConvexClaimBasis(walletId: string | null | undefined): Record<string, number> | undefined {
  const state = useQuery(
    api.sandbox.onboarding.getWalletOnboardingState,
    useAuthedQueryArgs(walletId ? { wallet: walletId } : null),
  )
  return useMemo(() => {
    if (state === undefined) return undefined
    const basket = state?.profile?.basketSnapshot
    if (!basket) return {}
    const basis: Record<string, number> = {}
    for (const leg of basket) {
      if (leg.priceUsdAtClaim > 0) basis[leg.tokenId.toLowerCase()] = leg.priceUsdAtClaim
    }
    return basis
  }, [state])
}

/**
 * Onboarding-derived facts for the Wallet Overview tiles, from the same query as the cost
 * basis (so the two share one Convex subscription):
 *   - `sinceMs` — when the wallet came aboard: `onboardedAt` (claim completed) → `createdAt`
 *     (first touch) fallback. Powers "Member since".
 *   - `boost` — the per-wallet reward multiplier (`eligibilityTier`, ~0.8–1.2, deterministic
 *     from the wallet). Powers "Avana Boost".
 * `undefined` while loading; fields are `null` when the wallet has no profile yet.
 */
export function useConvexWalletOnboardingSummary(
  walletId: string | null | undefined,
): { sinceMs: number | null; boost: number | null } | undefined {
  const state = useQuery(
    api.sandbox.onboarding.getWalletOnboardingState,
    useAuthedQueryArgs(walletId ? { wallet: walletId } : null),
  )
  return useMemo(() => {
    if (state === undefined) return undefined
    const profile = state?.profile
    if (!profile) return { sinceMs: null, boost: null }
    return {
      sinceMs: profile.onboardedAt ?? profile.createdAt ?? null,
      boost: profile.eligibilityTier ?? null,
    }
  }, [state])
}

export function useConvexProductWalletBalances(walletId: string | null | undefined): UserAssetBalance[] | undefined {
  const buckets = useQuery(
    api.wallet.productBalances.listForWallet,
    useAuthedQueryArgs(walletId ? { wallet: walletId } : null),
  )
  if (!buckets) return buckets === undefined ? undefined : []
  const resolvedWalletId = walletId ?? ""

  const rows: UserAssetBalance[] = []
  for (const row of buckets.liquid) {
    rows.push({
      id: String(row._id),
      walletId: resolvedWalletId,
      assetId: row.assetId,
      amount: row.amount,
      valueUsd: row.valueUsd,
      sourceType: "wallet",
    })
  }
  for (const row of buckets.lend) {
    rows.push({
      id: String(row._id),
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
      id: String(row._id),
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
  for (const row of buckets.multiply) {
    if (row.state === "collateral") continue
    rows.push({
      id: String(row._id),
      walletId: resolvedWalletId,
      assetId: row.assetId,
      amount: row.amount,
      valueUsd: row.state === "debt" ? -row.valueUsd : row.valueUsd,
      sourceType:
        row.state === "available" ? "multiply_available" : row.state === "debt" ? "multiply_debt" : "multiply_active",
      sourcePositionId: row.marketId,
    })
  }
  return rows
}
