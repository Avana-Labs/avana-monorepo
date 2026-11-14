import { describe, expect, it } from "vitest"
import { calculateSpokeCreditMetrics, formatFixed, parseFixed } from "@/app/lib/borrow-system/model"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { resolveBorrowAprPct, selectBorrowableAssets } from "@/app/lib/borrow-system/selectors"
import { selectPortfolioDebtRows } from "@/app/lib/borrow-system/dashboard-selectors"

/**
 * C2 — one borrow-APR source across list / dashboard / detail.
 *
 * The borrow list (selectBorrowableAssets), the dashboard debt rows
 * (selectPortfolioDebtRows) and the detail IRM headline must all report the SAME
 * "base rate + risk premium" for a given asset — never base-only on one surface and
 * base+premium on another. The detail headline is produced by the Convex query
 * (convex/borrow/interestRateModel.ts), which can't run in vitest; this test pins the
 * shared TS source (resolveBorrowAprPct) that the list + dashboard route through, and
 * asserts they agree on an asset with a nonzero risk premium.
 */
describe("borrow APR single source (base + risk premium)", () => {
  const walletId = "demo-wallet"
  const state = buildMockBorrowSystemState(walletId)

  it("list and dashboard debt rows report the identical base+premium APR for the same asset", () => {
    const debts = selectPortfolioDebtRows(state, walletId)
    expect(debts.length).toBeGreaterThan(0)

    let sawNonzeroPremium = false
    for (const debtRow of debts) {
      const position = state.accounts[walletId]!.debtPositions.find((entry) => entry.id === debtRow.id)!
      const asset = state.assets[position.assetId]!
      const premiumWad = calculateSpokeCreditMetrics(state, walletId, position.spokeId).riskPremiumWad
      const baseAprPct = Number.parseFloat(formatFixed(asset.borrowConfig.baseBorrowAprWad, 18)) * 100

      const expected = resolveBorrowAprPct(asset.borrowConfig.baseBorrowAprWad, premiumWad)

      // Detail path (Convex) = base + premium; assert the shared source includes the premium
      // rather than the base-only walked daily-stat value the finding flagged.
      if (premiumWad > 0n) {
        sawNonzeroPremium = true
        expect(expected).toBeGreaterThan(baseAprPct)
      }

      // Borrow list ↔ dashboard debt row: same asset, same market, identical APR.
      const listRow = selectBorrowableAssets(state, walletId, position.marketId).find(
        (row) => row.id === position.assetId,
      )!
      expect(listRow.borrowApr).toBeCloseTo(expected, 9)
      expect(debtRow.borrowApr).toBeCloseTo(expected, 9)
    }

    expect(sawNonzeroPremium).toBe(true)
  })

  it("resolveBorrowAprPct is a pure base + premium sum", () => {
    // 4% base + 150bps premium = 5.5%.
    const base = parseFixed("0.04", 18)
    const premium = parseFixed("0.015", 18)
    expect(resolveBorrowAprPct(base, premium)).toBeCloseTo(5.5, 9)
    expect(resolveBorrowAprPct(base, 0n)).toBeCloseTo(4, 9)
  })
})
