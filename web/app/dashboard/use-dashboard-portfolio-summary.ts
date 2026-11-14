"use client"

import { useMemo } from "react"
import { useQuery } from "convex/react"
import { useAuthedQueryArgs } from "@/app/lib/convex/use-authed-query-args"
import { api } from "@/convex/_generated/api"
import { getSwapAsset } from "@/app/lib/swap-system/catalog"
import type { UserAssetBalance } from "@/app/lib/swap-system"
import { buildDashboardWalletBalanceRows, selectDashboardWalletValueRows } from "@/app/lib/swap-system"
import { useConvexProductWalletBalances } from "@/app/lib/swap-system/use-convex-wallet-balances"
import { useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"
import { useBorrowSessionContext, useLendSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { useHasMounted } from "@/app/lib/ui/use-has-mounted"
import { buildPortfolioLendData } from "@/app/lib/lend-system/read-model"
import { buildBorrowBalanceMetrics, buildLendDashboardMetrics } from "@/app/dashboard/dashboard-tab-metrics"
import { sumWalletValueUsd } from "@/app/dashboard/dashboard-wallet-tab"
import { blendEquityWeightedNetApyPct, resolveDashboardNetApyPct } from "@/app/dashboard/portfolio-headline-metrics"

type DashboardPortfolioSummary = {
  /** Net Portfolio Value (Assets − Debt), aggregated across products. Umbrella excluded. */
  netValueUsd: number
  /** Value-weighted blended Net APY. Umbrella excluded. */
  netApyPct: number
  /** Wallet-accessible funds, including returned available product balances (same scope as the Wallet tab). */
  walletBalanceUsd: number
}

/**
 * Global Net Value = signed sum of the wallet's product balances, debt rows negative.
 * Umbrella is never in productBalances, so it is excluded by construction. The product
 * tabs re-derive their own nets client-side from the same source, so they reconcile but
 * are not identical; the `hero == Σ product nets` invariant is pinned by
 * dashboard-net-value-parity.test.ts.
 */

/**
 * Widest gap tolerated between a row's implied unit price (`valueUsd / amount`) and the
 * live oracle price before `amount` stops being trusted as a token quantity. A real
 * intra-session price move is bounded; a units mismatch is orders of magnitude off.
 */
const AMOUNT_TRUST_DRIFT_BAND = { min: 0.1, max: 10 } as const

/** How far a live price may sit from $1 and still count as peg-like (reprice is harmless). */
const AMOUNT_USD_PEG_TOLERANCE = 0.05

/**
 * True when `row.amount` can be trusted as a token quantity and repriced live.
 *
 * Some writers store USD in `amount` instead of a token count: the multiply debt row
 * writes `amount: debtValueUsd`, and `adjustProductBalanceUsd` uses `priceUsd = 1` when it
 * CREATES a row, so a first deposit into a market lands USD there. Repricing those as
 * `amount × livePrice` multiplies the position by the token price (1 AAVE lend deposit
 * contributed $14,443). The stored `valueUsd` is correct in those cases, so fall back to it.
 *
 * Detection: such rows have an implied unit price of exactly 1. A real token implies its
 * own price, and a ~$1 token's live price is also ≈1 (harmless). So implied ≈1 with live
 * NOT ≈1 means USD-in-amount for any token — this catches sub-$10 tokens whose price sits
 * inside the drift band, which the band alone let through.
 */
function amountIsTokenDenominated(amount: number, valueUsd: number, livePriceUsd: number): boolean {
  if (!(amount > 0) || !(valueUsd > 0)) return false
  const impliedPriceUsd = valueUsd / amount
  if (!Number.isFinite(impliedPriceUsd) || impliedPriceUsd <= 0) return false
  const impliedIsUsdLike = Math.abs(impliedPriceUsd - 1) < 1e-4
  const liveIsUsdLike = Math.abs(livePriceUsd - 1) <= AMOUNT_USD_PEG_TOLERANCE
  if (impliedIsUsdLike && !liveIsUsdLike) return false
  const scale = livePriceUsd / impliedPriceUsd
  if (!Number.isFinite(scale)) return false
  return scale >= AMOUNT_TRUST_DRIFT_BAND.min && scale <= AMOUNT_TRUST_DRIFT_BAND.max
}

/**
 * Product buckets that MIRROR liquid wallet holdings rather than holding separate capital, so
 * counting both double-counts the same tokens. Matches `selectDashboardWalletValueRows`, which
 * already applies this rule on the Wallet tab — Net Value read the raw rows and did not, so a
 * lend withdrawal (which credits BOTH `walletLiquidBalances` and the lend `available` bucket)
 * permanently inflated the headline by the withdrawn amount.
 *
 * `multiply_available` is deliberately absent: it is a separate equity budget allocated to
 * Multiply, not a mirror of a liquid row.
 */
const LIQUID_MIRROR_SOURCE_TYPES = new Set(["lend_available", "borrow_collateral_unpledged"])

export function aggregateNetValueUsd(
  rows: readonly UserAssetBalance[],
  priceFor: (symbol: string) => number | undefined,
): number {
  const liquidAssetIds = new Set(rows.filter((row) => row.sourceType === "wallet").map((row) => row.assetId))
  let total = 0
  for (const row of rows) {
    if (LIQUID_MIRROR_SOURCE_TYPES.has(row.sourceType) && liquidAssetIds.has(row.assetId)) continue
    const stored = row.valueUsd ?? 0
    const asset = getSwapAsset(row.assetId)
    const isLp = asset?.isLpToken ?? false
    const live = isLp ? undefined : priceFor(asset?.symbol ?? row.assetId)
    // Multiply available buckets store a USD budget. Legacy rows can contain
    // that USD budget again in `amount`, so valuing them as `amount × price`
    // inflates Net Value into the millions. Their stored USD value is canonical.
    const isMultiplyAvailable = row.sourceType === "multiply_available"
    const magnitude =
      isMultiplyAvailable || live == null || !Number.isFinite(live)
        ? Math.abs(stored)
        : amountIsTokenDenominated(row.amount, Math.abs(stored), live)
          ? row.amount * live
          : Math.abs(stored)
    // productBalances encodes debt as a negative stored valueUsd; preserve that sign.
    total += (stored < 0 ? -1 : 1) * magnitude
  }
  return total
}

/**
 * Your Dashboard headlines: Wallet Balance (wallet-accessible), Net Value (all products),
 * and Net APY (equity-weighted blend of Lend / Borrow session metrics).
 */
export function useDashboardPortfolioSummary(walletId: string | undefined): DashboardPortfolioSummary {
  const hasMounted = useHasMounted()
  const balances = useConvexProductWalletBalances(walletId)
  const priceFor = useCanonicalPriceFor()
  const portfolio = useQuery(
    api.sandbox.transactions.getPortfolio,
    useAuthedQueryArgs(walletId ? { wallet: walletId } : null),
  )
  const borrowSession = useBorrowSessionContext()
  const lendSession = useLendSessionContext()

  const walletRows = selectDashboardWalletValueRows(
    buildDashboardWalletBalanceRows({
      walletId: walletId ?? "",
      balances: balances ?? undefined,
      priceFor,
    }),
  )
  const walletBalanceUsd = sumWalletValueUsd(walletRows)

  const productNetValueUsd = aggregateNetValueUsd(balances ?? [], priceFor)

  const clientMetrics = useMemo(() => {
    if (!hasMounted || !walletId) return { netApyPct: null as number | null, netAccruedInterestUsd: 0 }

    const legs: Array<{ equityUsd: number; netApyPct: number }> = []
    // Interest each product has earned (+) or owes (−) since its positions opened. The
    // productBalances aggregate values every position at its PRINCIPAL basis (seed USD, or
    // amount × live price for repriced legs) and never folds in the accrued yield/cost, so the
    // headline sat below the tabs by exactly this net carry — Lend "Interest Earned" minus Borrow
    // "Interest Owed". These are the same figures the tabs already
    // compute from each position's openedAt; crediting them on read (never a stored rate, matching
    // every other dashboard metric) makes Net Value reflect earnings instead of frozen principal.
    let netAccruedInterestUsd = 0

    try {
      const lendTab = buildPortfolioLendData(walletId, lendSession.state)
      const lendMetrics = buildLendDashboardMetrics(lendTab)
      if (lendMetrics.totalSuppliedUsd > 0) {
        legs.push({ equityUsd: lendMetrics.totalSuppliedUsd, netApyPct: lendMetrics.netApyPct })
      }
      netAccruedInterestUsd += lendMetrics.interestEarnedUsd
    } catch {
      // Session may not be hydrated yet.
    }

    try {
      if (borrowSession.state.accounts[walletId]) {
        const borrow = buildBorrowBalanceMetrics(borrowSession.state, walletId)
        if (borrow.netValueUsd > 0) {
          legs.push({ equityUsd: borrow.netValueUsd, netApyPct: borrow.netApyPct })
        }
        // Accrued debt interest is a cost — it grows what the wallet owes, so it reduces net value.
        netAccruedInterestUsd -= borrow.interestOwedUsd
      }
    } catch {
      // ignore
    }

    return { netApyPct: blendEquityWeightedNetApyPct(legs), netAccruedInterestUsd }
  }, [borrowSession.state, hasMounted, lendSession.state, walletId])

  return {
    walletBalanceUsd,
    // Live-priced productBalances aggregate (principal basis) PLUS the net interest accrued across
    // products, so the headline reflects earned yield rather than frozen principal. The aggregate
    // never carries that interest, so there is no double-count with the credit-engine net.
    netValueUsd: productNetValueUsd + clientMetrics.netAccruedInterestUsd,
    netApyPct: resolveDashboardNetApyPct(clientMetrics.netApyPct, portfolio?.netApyPct),
  }
}
