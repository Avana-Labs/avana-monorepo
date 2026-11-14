import { describe, expect, it } from "vitest"
import { makeExampleBorrowSystemState } from "@/app/lib/credit-engine/__tests__/fixtures"
import {
  makeStressMultiplyActions,
  makeStressMultiplySystemState,
} from "@/app/lib/multiply-engine/__tests__/stress-fixtures"
import { SandboxMultiplyReadAdapter } from "@/app/lib/multiply-system/sandbox-read-adapter"
import { SandboxMultiplyTransactionAdapter } from "@/app/lib/multiply-system/sandbox-transaction-adapter"

describe("multiply adapter 100-user scale", () => {
  it(
    "executes 100 wallet actions through the transaction adapter and keeps reads consistent",
    { timeout: 30_000 },
    async () => {
      const initialState = makeStressMultiplySystemState(100)
      let state = initialState
      let idCounter = 0

      const adapter = new SandboxMultiplyTransactionAdapter({
        readState: () => state,
        writeState: (nextState) => {
          state = nextState
        },
        now: () => 1_718_800_000_000 + idCounter,
        generateId: (prefix: string) => `${prefix}-${++idCounter}`,
      })

      const actions = makeStressMultiplyActions(initialState)
      const receipts = []

      for (const action of actions) {
        const intent = adapter.createIntent(action)
        const result = await adapter.executeTransaction(intent)
        receipts.push(result.receipt)
      }

      expect(receipts.length).toBe(actions.length)
      expect(receipts.every((receipt) => receipt.simulated)).toBe(true)
      expect(receipts.filter((receipt) => receipt.status === "success").length).toBeGreaterThan(50)

      const readAdapter = new SandboxMultiplyReadAdapter({ state })
      const sampledWalletIds = [
        "wallet-multiply-stress-0",
        "wallet-multiply-stress-7",
        "wallet-multiply-stress-25",
        "wallet-multiply-stress-50",
        "wallet-multiply-stress-99",
      ]

      for (const walletId of sampledWalletIds) {
        const portfolio = await readAdapter.readPortfolioMultiply(walletId)
        const snapshot = await readAdapter.readWalletSnapshot(walletId)
        expect(Number.isFinite(portfolio.creditLines.totalCollateralUsd)).toBe(true)
        expect(snapshot.transactionHistory.every((item) => item.simulated)).toBe(true)
      }

      const borrowState = makeExampleBorrowSystemState()
      const borrowCollateralBefore = borrowState.accounts["wallet-1"]!.collateralPositions.length
      expect(borrowCollateralBefore).toBeGreaterThan(0)
      expect(Object.keys(state.positions).length).toBeGreaterThan(0)
    },
  )

  it("previewTransaction does not mutate multiply state for 100 wallets", async () => {
    const initialState = makeStressMultiplySystemState(100)
    const adapter = new SandboxMultiplyTransactionAdapter({
      readState: () => initialState,
      writeState: () => {
        throw new Error("writeState should not be called during preview")
      },
    })

    const previews = await Promise.all(
      Array.from({ length: 100 }, (_, index) => {
        const walletId = `wallet-multiply-stress-${index}`
        const marketId = Object.keys(initialState.markets)[index % Object.keys(initialState.markets).length]!
        const market = initialState.markets[marketId]!
        const positionId = `${walletId}:${marketId}`
        const existing = initialState.positions[positionId]

        if (existing) {
          return adapter.previewTransaction(
            adapter.createIntent({
              type: "deleverage",
              walletId,
              positionId,
              targetMultiplier: Math.max(1.2, existing.multiplier - 0.4),
            }),
          )
        }

        return adapter.previewTransaction(
          adapter.createIntent({
            type: "multiply",
            walletId,
            marketId,
            collateralAmount: 0.5,
            selectedMultiplier: Math.min(2, market.risk.publicMaxMultiplier),
          }),
        )
      }),
    )

    expect(previews).toHaveLength(100)
    expect(previews.every((preview) => preview.intent.simulated)).toBe(true)
  })
})
