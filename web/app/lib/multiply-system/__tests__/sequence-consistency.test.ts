import { describe, expect, it } from "vitest"
import { assertMultiplySystemInvariants } from "@/app/lib/multiply-engine"
import { makeExampleMultiplySystemState } from "@/app/lib/multiply-engine/__tests__/fixtures"
import { SandboxMultiplyTransactionAdapter } from "@/app/lib/multiply-system/sandbox-transaction-adapter"

describe("multiply repeated session sequences", () => {
  it("can add and then fully unwind the same position back to 1x", async () => {
    let state = makeExampleMultiplySystemState()
    const positionId = "wallet-1:eth-usdt"
    let idCounter = 0

    const adapter = new SandboxMultiplyTransactionAdapter({
      readState: () => state,
      writeState: (nextState) => {
        state = nextState
      },
      now: () => state.now + ++idCounter,
      generateId: (prefix: string) => `${prefix}-${idCounter}`,
    })

    for (let index = 0; index < 5; index += 1) {
      const marketId = state.positions[positionId]!.marketId
      const addIntent = adapter.createIntent({
        type: "multiply",
        walletId: "wallet-1",
        marketId,
        collateralAmount: 0.15 + index * 0.05,
        selectedMultiplier: Math.min(2.8, state.markets[marketId]!.risk.publicMaxMultiplier),
      })
      const addResult = await adapter.executeTransaction(addIntent)
      expect(addResult.receipt.status).toBe("success")

      const updatedPosition = state.positions[positionId]!
      const unwindIntent = adapter.createIntent({
        type: "deleverage",
        walletId: "wallet-1",
        positionId,
        targetMultiplier: Math.max(1.4, updatedPosition.multiplier - 0.45),
      })
      const unwindResult = await adapter.executeTransaction(unwindIntent)
      expect(unwindResult.receipt.status).toBe("success")
    }

    const finalUnwindIntent = adapter.createIntent({
      type: "deleverage",
      walletId: "wallet-1",
      positionId,
      targetMultiplier: 1,
    })
    const finalUnwind = await adapter.executeTransaction(finalUnwindIntent)
    const finalPosition = state.positions[positionId]!

    assertMultiplySystemInvariants(state)
    expect(finalUnwind.receipt.status).toBe("success")
    expect(finalPosition.debtValueUsd).toBeCloseTo(0, 6)
    expect(finalPosition.multiplier).toBeCloseTo(1, 6)
    expect(finalPosition.healthFactor).toBe("infinity")
    expect(finalPosition.netApy).toBeCloseTo(state.markets[finalPosition.marketId]!.economics.supplyApy, 6)
    expect(state.transactions.at(-1)?.kind).toBe("deleverage")
  })
})
