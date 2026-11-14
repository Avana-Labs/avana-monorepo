import { describe, expect, it } from "vitest"
import { applyBorrowActions, assertBorrowSystemInvariants, calculateCreditMetrics } from "@/app/lib/credit-engine"
import { SandboxBorrowReadAdapter } from "@/app/lib/borrow-system/sandbox-read-adapter"
import { makeHeterogeneousStressBorrowActions, makeHeterogeneousStressBorrowSystemState } from "./stress-fixtures"

describe("heterogeneous 1k borrow scale", () => {
  it(
    "settles 1k heterogeneous wallets with 1k+ writes and keeps adapter reads consistent",
    { timeout: 120_000 },
    async () => {
      const initialState = makeHeterogeneousStressBorrowSystemState(1_000)
      const actions = makeHeterogeneousStressBorrowActions(initialState, 1_000)
      const nextState = applyBorrowActions(initialState, actions)
      const adapter = new SandboxBorrowReadAdapter({ state: nextState })

      expect(Object.keys(nextState.accounts)).toHaveLength(1_000)
      expect(nextState.transactions.length).toBeGreaterThan(1_000)
      assertBorrowSystemInvariants(nextState)

      const sampledWalletIds = ["wallet-stress-0", "wallet-stress-125", "wallet-stress-500", "wallet-stress-999"]

      for (const walletId of sampledWalletIds) {
        const metrics = calculateCreditMetrics(nextState, walletId)
        expect(metrics.poolCollateralValueUsd6).toBeGreaterThan(0n)
        expect(metrics.totalBorrowedUsd6).toBeGreaterThanOrEqual(0n)

        const portfolioBorrow = await adapter.readPortfolioBorrow(walletId)
        const walletSnapshot = await adapter.readWalletSnapshot(walletId)

        expect(portfolioBorrow.creditLines.totalCollateralUsd).toBeGreaterThan(0)
        expect(Number.isFinite(portfolioBorrow.creditLines.currentLtvPct)).toBe(true)
        expect(walletSnapshot.transactionHistory.every((item) => item.simulated)).toBe(true)
      }

      const whale = await adapter.readPortfolioBorrow("wallet-stress-0")
      const regular = await adapter.readPortfolioBorrow("wallet-stress-7")
      expect(whale.creditLines.totalCollateralUsd).toBeGreaterThan(regular.creditLines.totalCollateralUsd)
    },
  )
})
