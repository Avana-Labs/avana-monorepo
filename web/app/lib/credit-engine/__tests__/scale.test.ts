import { describe, expect, it } from "vitest"
import { applyBorrowActions, assertBorrowSystemInvariants, calculateCreditMetrics } from "@/app/lib/credit-engine"
import { SandboxBorrowReadAdapter } from "@/app/lib/borrow-system/sandbox-read-adapter"
import { makeHeterogeneousStressBorrowActions, makeHeterogeneousStressBorrowSystemState } from "./stress-fixtures"

describe("borrow system scale", () => {
  // This 10k-wallet pass runs ~36s in isolation; allow headroom for CPU contention
  // when the full suite runs it alongside the other heavy stress files.
  it(
    "keeps 10,000 heterogeneous wallet sessions readable while an active subset settles actions consistently",
    { timeout: 180_000 },
    async () => {
      const initialState = makeHeterogeneousStressBorrowSystemState(10_000)
      const actions = makeHeterogeneousStressBorrowActions(initialState, 250)
      const nextState = applyBorrowActions(initialState, actions)
      const adapter = new SandboxBorrowReadAdapter({ state: nextState })

      expect(Object.keys(nextState.accounts)).toHaveLength(10_000)
      expect(nextState.transactions).toHaveLength(actions.length)
      assertBorrowSystemInvariants(nextState)

      const sampledWalletIds = ["wallet-stress-0", "wallet-stress-1", "wallet-stress-2222", "wallet-stress-9999"]

      for (const walletId of sampledWalletIds) {
        const metrics = calculateCreditMetrics(nextState, walletId)
        expect(metrics.poolCollateralValueUsd6).toBeGreaterThan(0n)
        expect(metrics.totalBorrowedUsd6).toBeGreaterThanOrEqual(0n)
        expect(metrics.availableCreditUsd6).toBeGreaterThanOrEqual(0n)
        expect(metrics.healthFactorWad === null || metrics.healthFactorWad > 0n).toBe(true)

        const portfolioBorrow = await adapter.readPortfolioBorrow(walletId)
        const walletSnapshot = await adapter.readWalletSnapshot(walletId)

        expect(portfolioBorrow.creditLines.totalCollateralUsd).toBeGreaterThan(0)
        expect(Number.isFinite(portfolioBorrow.creditLines.totalCollateralUsd)).toBe(true)
        expect(Number.isFinite(portfolioBorrow.creditLines.totalBorrowedUsd)).toBe(true)
        expect(walletSnapshot.transactionHistory.every((item) => item.simulated)).toBe(true)
      }

      const whaleBorrow = await adapter.readPortfolioBorrow("wallet-stress-0")
      const regularBorrow = await adapter.readPortfolioBorrow("wallet-stress-7")
      const borrowPage = await adapter.readBorrowPage("wallet-stress-0")

      expect(whaleBorrow.creditLines.totalCollateralUsd).toBeGreaterThan(regularBorrow.creditLines.totalCollateralUsd)
      expect(whaleBorrow.collateralPositions.length).toBeGreaterThan(0)
      expect(borrowPage.heroMetrics.totalTvlUsd).toBeGreaterThan(0)
      expect(Number.isFinite(borrowPage.heroMetrics.totalTvlUsd)).toBe(true)
      expect(borrowPage.poolCatalog.length).toBeGreaterThan(0)
    },
  )
})
