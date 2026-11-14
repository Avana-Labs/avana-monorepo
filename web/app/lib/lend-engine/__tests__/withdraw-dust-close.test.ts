import { describe, expect, it } from "vitest"
import { applyLendAction } from "@/app/lib/lend-engine/actions"
import { buildMockLendMarket } from "@/app/lib/lend-system/mock"
import type { LendSystemState } from "@/app/lib/lend-engine/types"

// usdc market: assetPriceUsd = 1, so an asset-unit remainder maps 1:1 to USD.
function depositedState(depositAmount: number) {
  const market = buildMockLendMarket("usdc")
  const seed: LendSystemState = {
    now: market.lastAccrualTimestamp,
    markets: { [market.marketId]: market },
    positions: {},
    walletBalances: { "wallet-1": { [market.marketId]: depositAmount * 2 } },
    transactions: [],
  }
  const state = applyLendAction(
    seed,
    {
      type: "deposit",
      walletId: "wallet-1",
      marketId: market.marketId,
      depositAmount,
      walletBalance: depositAmount * 2,
    },
    { positionId: "pos-1", transactionId: "tx-deposit" },
  )
  return { state, marketId: market.marketId }
}

describe("full withdraw dust close", () => {
  it("closes the position and sweeps sub-cent dust on a near-full withdraw", () => {
    const { state, marketId } = depositedState(1000)
    const walletBefore = state.walletBalances["wallet-1"]![marketId]!

    // Leave 0.005 usdc (~$0.005) behind — below the $0.01 dust threshold.
    const withdrawAmount = 999.995
    const next = applyLendAction(
      state,
      { type: "withdraw", walletId: "wallet-1", marketId, positionId: "pos-1", withdrawAmount, at: state.now },
      { positionId: "pos-1", transactionId: "tx-withdraw" },
    )

    const position = next.positions["pos-1"]!
    expect(position.status).toBe("closed")
    expect(position.currentSuppliedAmount).toBe(0)
    expect(position.suppliedValueUsd).toBe(0)

    // The dust remainder is swept into this withdraw (accrued balance paid out).
    const walletAfter = next.walletBalances["wallet-1"]![marketId]!
    expect(walletAfter - walletBefore).toBeCloseTo(1000, 6)
    const withdrawTx = next.transactions.find((tx) => tx.kind === "withdraw")!
    expect(withdrawTx.amount).toBeCloseTo(1000, 6)
  })

  it("keeps the position active on a partial withdraw that leaves a real balance", () => {
    const { state, marketId } = depositedState(1000)
    const next = applyLendAction(
      state,
      { type: "withdraw", walletId: "wallet-1", marketId, positionId: "pos-1", withdrawAmount: 400, at: state.now },
      { positionId: "pos-1", transactionId: "tx-withdraw" },
    )

    const position = next.positions["pos-1"]!
    expect(position.status).toBe("active")
    expect(position.currentSuppliedAmount).toBeCloseTo(600, 6)
    const withdrawTx = next.transactions.find((tx) => tx.kind === "withdraw")!
    expect(withdrawTx.amount).toBe(400)
  })
})
