import { describe, expect, it } from "vitest"
import { makeExampleBorrowSystemState } from "@/app/lib/borrow-system/model/__tests__/fixtures"
import { makeStressLendActions, makeStressLendSystemState } from "@/app/lib/lend-system/model/__tests__/stress-fixtures"
import { SandboxLendReadAdapter } from "@/app/lib/lend-system/sandbox-read-adapter"
import { SandboxLendTransactionAdapter } from "@/app/lib/lend-system/sandbox-transaction-adapter"

describe("lend adapter 100-user scale", () => {
  it(
    "executes 100 wallet actions through the transaction adapter and keeps reads consistent",
    { timeout: 30_000 },
    async () => {
      const initialState = makeStressLendSystemState(100)
      let state = initialState
      let idCounter = 0

      const adapter = new SandboxLendTransactionAdapter({
        readState: () => state,
        writeState: (nextState) => {
          state = nextState
        },
        now: () => 1_718_800_000_000 + idCounter,
        generateId: (prefix: string) => `${prefix}-${++idCounter}`,
      })

      const actions = makeStressLendActions(initialState)
      const receipts = []

      for (const action of actions) {
        const intent = adapter.createIntent(action)
        const preview = await adapter.previewTransaction(intent)
        if (!preview.allowed) {
          receipts.push({
            status: "failed",
            simulated: true,
          })
          continue
        }
        const result = await adapter.executeTransaction(intent)
        receipts.push(result.receipt)
      }

      expect(receipts.length).toBe(actions.length)
      expect(receipts.every((receipt) => receipt.simulated)).toBe(true)
      expect(receipts.filter((receipt) => receipt.status === "success").length).toBeGreaterThan(50)

      const readAdapter = new SandboxLendReadAdapter({ state, transactionHistory: [] })
      const sampledWalletIds = [
        "wallet-lend-stress-0",
        "wallet-lend-stress-7",
        "wallet-lend-stress-25",
        "wallet-lend-stress-50",
        "wallet-lend-stress-99",
      ]

      for (const walletId of sampledWalletIds) {
        const portfolio = await readAdapter.readPortfolioLend(walletId)
        const snapshot = await readAdapter.readWalletSnapshot(walletId)
        expect(Number.isFinite(snapshot.metrics.suppliedValueUsd)).toBe(true)
        expect(portfolio.investments.every((item) => Number.isFinite(item.suppliedUsd))).toBe(true)
      }

      const borrowState = makeExampleBorrowSystemState()
      const borrowCollateralBefore = borrowState.accounts["wallet-1"]!.collateralPositions.length
      expect(borrowCollateralBefore).toBeGreaterThan(0)
      expect(Object.keys(state.positions).length).toBeGreaterThan(0)
    },
  )

  it("previewTransaction does not mutate lend state for 100 wallets", async () => {
    const initialState = makeStressLendSystemState(100)
    const adapter = new SandboxLendTransactionAdapter({
      readState: () => initialState,
      writeState: () => {
        throw new Error("writeState should not be called during preview")
      },
    })

    const marketIds = Object.keys(initialState.markets)
    const previews = await Promise.all(
      Array.from({ length: 100 }, (_, index) => {
        const walletId = `wallet-lend-stress-${index}`
        const marketId = marketIds[index % marketIds.length]!
        const positionId = `${walletId}:${marketId}`
        const existing = initialState.positions[positionId]

        if (existing) {
          return adapter.previewTransaction(
            adapter.createIntent({
              type: "withdraw",
              walletId,
              marketId,
              positionId,
              withdrawAmount: Math.min(existing.currentSuppliedAmount * 0.1, existing.currentSuppliedAmount),
            }),
          )
        }

        return adapter.previewTransaction(
          adapter.createIntent({
            type: "deposit",
            walletId,
            marketId,
            depositAmount: 50,
            walletBalance: 10_000,
          }),
        )
      }),
    )

    expect(previews).toHaveLength(100)
    expect(previews.every((preview) => preview.intent.simulated)).toBe(true)
  })
})
