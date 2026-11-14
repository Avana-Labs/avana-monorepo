import { calculateMaxLeverageApy } from "@/app/lib/multiply-engine"
import type { MultiplySystemState } from "@/app/lib/multiply-engine"
import { resolveMultiplyMarketDisplayMaxLeverage } from "@/app/lib/multiply-system/leverage-limits"
import { warnLiveFallback } from "@/app/lib/data/providers/hydration-telemetry"

/**
 * One multiply row from convex/markets.ts `listMarketSnapshots` (scope === "multiply").
 * Loose `scope: string` so the raw query result (which also carries other scopes) is
 * assignable without a cast.
 *
 * `availableUsd` is the list↔detail SoT for available liquidity (supplied − borrowed).
 * Do not map `suppliedUsd` into available — that diverges from detail quick stats.
 */
export type MultiplyConvexSnapshot = {
  slug: string
  scope: string
  name?: string
  symbol?: string
  maxLtvPct?: number
  reserveFactorPct?: number
  suppliedUsd: number
  borrowedUsd?: number
  availableUsd?: number
  utilizationPct: number
  supplyApyPct: number
  borrowAprPct: number
}

/** Resolve available liquidity for list/detail from a multiply snapshot row. */
export function multiplyAvailableLiquidityUsd(
  snap: Pick<MultiplyConvexSnapshot, "suppliedUsd" | "borrowedUsd" | "availableUsd">,
) {
  if (snap.availableUsd !== undefined && Number.isFinite(snap.availableUsd)) {
    return Math.max(0, snap.availableUsd)
  }
  if (snap.borrowedUsd !== undefined && Number.isFinite(snap.borrowedUsd)) {
    return Math.max(0, snap.suppliedUsd - snap.borrowedUsd)
  }
  return Math.max(0, snap.suppliedUsd)
}

/**
 * Fold Convex multiply market reference data into a multiply system state so the
 * list/trending read the SAME numbers as the detail page and the single source of
 * truth. Updates available liquidity, supply/borrow APY, estimatedMaxApy (aligned
 * with trending), and identity when present.
 */
export function mergeConvexMultiplySnapshots(
  state: MultiplySystemState,
  snapshots: readonly MultiplyConvexSnapshot[],
): MultiplySystemState {
  if (snapshots.length === 0) return state
  let changed = false
  const markets = { ...state.markets }

  for (const snap of snapshots) {
    if (snap.scope !== "multiply") continue
    const existing = markets[snap.slug]
    if (!existing) continue

    const availableLiquidityUsd = multiplyAvailableLiquidityUsd(snap)
    const utilizationPct = Number.isFinite(snap.utilizationPct)
      ? Math.max(0, snap.utilizationPct)
      : existing.economics.utilizationPct
    const supplyApy = snap.supplyApyPct / 100
    const borrowApy = snap.borrowAprPct / 100
    const estimatedMaxApy = calculateMaxLeverageApy({
      supplyApy,
      borrowApy,
      safeMaxMultiplier: resolveMultiplyMarketDisplayMaxLeverage(existing.risk.publicMaxMultiplier),
    })

    const pairParts = snap.name?.includes(" / ") ? snap.name.split(" / ").map((part) => part.trim()) : null
    if (!snap.name?.trim()) warnLiveFallback("multiply", snap.slug, "name")
    if (!snap.symbol?.trim()) warnLiveFallback("multiply", snap.slug, "symbol")
    const nextCollateral = {
      ...existing.collateralAsset,
      symbol: snap.symbol?.trim() || existing.collateralAsset.symbol,
      name: pairParts?.[0] || existing.collateralAsset.name,
    }
    const nextBorrow = {
      ...existing.borrowAsset,
      symbol: pairParts?.[1] || existing.borrowAsset.symbol,
      name: pairParts?.[1] || existing.borrowAsset.name,
    }
    let nextRisk = existing.risk
    if (snap.maxLtvPct !== undefined && Number.isFinite(snap.maxLtvPct)) {
      nextRisk = { ...existing.risk, collateralFactor: snap.maxLtvPct / 100 }
    } else {
      warnLiveFallback("multiply", snap.slug, "maxLtvPct")
    }

    let nextReserveFactorPct: number | undefined
    if (snap.reserveFactorPct !== undefined && Number.isFinite(snap.reserveFactorPct)) {
      nextReserveFactorPct = snap.reserveFactorPct
    } else {
      warnLiveFallback("multiply", snap.slug, "reserveFactorPct")
      nextReserveFactorPct = existing.economics.reserveFactorPct
    }
    const e = existing.economics
    if (
      e.availableLiquidityUsd === availableLiquidityUsd &&
      e.utilizationPct === utilizationPct &&
      e.supplyApy === supplyApy &&
      e.borrowApy === borrowApy &&
      e.estimatedMaxApy === estimatedMaxApy &&
      e.reserveFactorPct === nextReserveFactorPct &&
      existing.collateralAsset.symbol === nextCollateral.symbol &&
      existing.collateralAsset.name === nextCollateral.name &&
      existing.borrowAsset.symbol === nextBorrow.symbol &&
      existing.borrowAsset.name === nextBorrow.name &&
      existing.risk.collateralFactor === nextRisk.collateralFactor
    ) {
      continue
    }

    markets[snap.slug] = {
      ...existing,
      collateralAsset: nextCollateral,
      borrowAsset: nextBorrow,
      risk: nextRisk,
      economics: {
        ...existing.economics,
        availableLiquidityUsd,
        utilizationPct,
        supplyApy,
        borrowApy,
        estimatedMaxApy,
        reserveFactorPct: nextReserveFactorPct,
      },
    }
    changed = true
  }

  return changed ? { ...state, markets } : state
}
