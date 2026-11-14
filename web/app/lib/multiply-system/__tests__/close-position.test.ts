import { describe, expect, it } from "vitest"
import { assertMultiplySystemInvariants } from "@/app/lib/multiply-engine"
import { makeExampleMultiplySystemState } from "@/app/lib/multiply-engine/__tests__/fixtures"
import { SandboxMultiplyReadAdapter } from "@/app/lib/multiply-system/sandbox-read-adapter"
import { SandboxMultiplyTransactionAdapter } from "@/app/lib/multiply-system/sandbox-transaction-adapter"

const POSITION_ID = "wallet-1:eth-usdt"

describe("multiply close position", () => {
  it("fully exits a position, reclaims collateral, and removes it from the dashboard", async () => {
    let state = makeExampleMultiplySystemState()
    let idCounter = 0
    const adapter = new SandboxMultiplyTransactionAdapter({
      readState: () => state,
      writeState: (nextState) => {
        state = nextState
      },
      now: () => state.now + ++idCounter,
      generateId: (prefix: string) => `${prefix}-${idCounter}`,
    })

    expect(state.positions[POSITION_ID]).toBeDefined()

    const intent = adapter.createIntent({ type: "close", walletId: "wallet-1", positionId: POSITION_ID })
    expect(intent.positionId).toBe(POSITION_ID)

    const preview = await adapter.previewTransaction(intent)
    expect(preview.allowed).toBe(true)
    expect(preview.after.collateralValueUsd).toBe(0)
    expect(preview.after.debtValueUsd).toBe(0)

    const result = await adapter.executeTransaction(intent)
    expect(result.receipt.status).toBe("success")
    expect(result.historyItem.kind).toBe("close")
    expect(result.historyItem.marketId).toBe("eth-usdt")

    // No zombie 1.0x/$0 position remains after close.
    expect(state.positions[POSITION_ID]).toBeUndefined()
    assertMultiplySystemInvariants(state)

    // Dashboard reflects the closed position (no multiply positions listed).
    const readAdapter = new SandboxMultiplyReadAdapter({ state })
    const portfolio = await readAdapter.readPortfolioMultiply("wallet-1")
    expect(portfolio.positions).toHaveLength(0)
  })
})
