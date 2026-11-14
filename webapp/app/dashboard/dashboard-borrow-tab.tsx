"use client"

import { useCallback, useMemo } from "react"
import { useRouter } from "next/navigation"
import { detailSectionStackClass } from "@/app/components/detail-page-primitives"
import { useAmountDisplayPreferences } from "@/app/components/display-preferences"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import type { DebtRowContext, SupplyRowContext } from "@/app/lib/data/borrow-position-types"
import { CurrentLtvCard, DebtsPanel } from "@/app/dashboard/borrow-tab/debts-table"
import { SuppliesHealthFactorCard, SuppliesPanel } from "@/app/dashboard/borrow-tab/supplies-table"

// Aggregate wallet-wide health factor: total liquidation value / total debt — the same
// definition used by the hero (map-portfolio-page / selectWalletBorrowSnapshot), rather
// than averaging per-row ratios, so the summary cards agree with the hero.
function aggregateHealthFactor(rows: Array<{ liquidationThresholdUsd: number; borrowedUsd: number }>): number | null {
  const totalDebt = rows.reduce((sum, row) => sum + row.borrowedUsd, 0)
  if (totalDebt <= 0) return null
  const totalLiquidation = rows.reduce((sum, row) => sum + row.liquidationThresholdUsd, 0)
  return totalLiquidation / totalDebt
}

function sortByCollateralDesc(rows: SupplyRowContext[]) {
  return [...rows].sort((left, right) => right.pool.collateralUsd - left.pool.collateralUsd)
}

function sortByBorrowedDesc(rows: DebtRowContext[]) {
  return [...rows].sort((left, right) => right.borrowedUsd - left.borrowedUsd)
}

export function DashboardBorrowTab({
  section = "all",
  collateralPositions = [],
  debtPositions = [],
  showSummary = true,
  returnHref,
}: {
  section?: "all" | "supplies" | "debts"
  collateralPositions?: SupplyRowContext[]
  debtPositions?: DebtRowContext[]
  showSummary?: boolean
  returnHref?: string
}) {
  const router = useRouter()
  const { showDollarAmounts } = useAmountDisplayPreferences()
  const supplies = collateralPositions
  const debtsRows = useMemo(() => debtPositions.filter((row) => row.borrowedUsd > 0), [debtPositions])
  const returnParams = returnHref ? { return: returnHref } : undefined

  const sortedSupplies = useMemo(() => sortByCollateralDesc(supplies), [supplies])
  const sortedDebts = useMemo(() => sortByBorrowedDesc(debtsRows), [debtsRows])

  const supplyTotals = useMemo(() => {
    const collateral = supplies.reduce((sum, row) => sum + row.pool.collateralUsd, 0)
    const borrowed = supplies.reduce((sum, row) => sum + row.borrowedUsd, 0)
    const available = supplies.reduce((sum, row) => sum + row.remainingBorrowPowerUsd, 0)
    const fees = supplies.reduce((sum, row) => sum + row.feesUsd, 0)
    const averageHf = aggregateHealthFactor(supplies.filter((row) => row.borrowedUsd > 0))
    return { collateral, borrowed, available, fees, averageHf }
  }, [supplies])

  const debtTotals = useMemo(() => {
    const totalBorrowed = debtsRows.reduce((sum, row) => sum + row.borrowedUsd, 0)
    const totalCollateral = debtsRows.reduce((sum, row) => sum + row.pool.collateralUsd, 0)
    const accruedInterest = debtsRows.reduce((sum, row) => sum + row.accruedInterestUsd, 0)
    const averageHf = aggregateHealthFactor(debtsRows)
    const dailyInterest = debtsRows.reduce((sum, row) => sum + row.dailyInterestUsd, 0)
    return { totalBorrowed, totalCollateral, accruedInterest, averageHf, dailyInterest }
  }, [debtsRows])

  const handleDebtRepay = useCallback(
    (context: DebtRowContext) => {
      router.push(actionPagePath("borrow", "repay", { market: context.pool.id, ...returnParams }))
    },
    [returnParams, router],
  )

  return (
    <section className={detailSectionStackClass}>
      {section === "all" ? (
        <>
          {showSummary ? (
            <div className="grid gap-4 xl:grid-cols-2">
              <SuppliesHealthFactorCard averageHealthFactor={supplyTotals.averageHf} showBalance={showDollarAmounts} />
              <CurrentLtvCard
                borrowedUsd={debtTotals.totalBorrowed}
                collateralUsd={debtTotals.totalCollateral}
                showBalance={showDollarAmounts}
                dailyInterestUsd={debtTotals.dailyInterest}
                accruedInterestUsd={debtTotals.accruedInterest}
              />
            </div>
          ) : null}

          <div className={detailSectionStackClass}>
            <DebtsPanel
              rows={sortedDebts}
              totals={debtTotals}
              onRepay={handleDebtRepay}
              showBalance={showDollarAmounts}
              showSummary={false}
            />
            <SuppliesPanel
              rows={sortedSupplies}
              totals={supplyTotals}
              showBalance={showDollarAmounts}
              showSummary={false}
            />
          </div>
        </>
      ) : (
        <>
          {section === "supplies" ? (
            <SuppliesPanel
              rows={sortedSupplies}
              totals={supplyTotals}
              showBalance={showDollarAmounts}
              showSummary={showSummary}
            />
          ) : null}
          {section === "debts" ? (
            <DebtsPanel
              rows={sortedDebts}
              totals={debtTotals}
              onRepay={handleDebtRepay}
              showBalance={showDollarAmounts}
              showSummary={showSummary}
            />
          ) : null}
        </>
      )}
    </section>
  )
}
