import { describe, expect, it } from "vitest"
import { assertBorrowSystemInvariants } from "@/app/lib/credit-engine/invariants"
import { makeExampleBorrowSystemState } from "./fixtures"

describe("borrow-system invariants", () => {
  it("accepts the example system state", () => {
    expect(() => assertBorrowSystemInvariants(makeExampleBorrowSystemState())).not.toThrow()
  })

  it("rejects unknown related assets", () => {
    const state = makeExampleBorrowSystemState()
    state.markets["uni-v3-bluechip-weth-usdc"]!.relations.supportedBorrowAssetIds.push("unknown-asset")

    expect(() => assertBorrowSystemInvariants(state)).toThrow("unknown asset")
  })

  it("rejects unknown wallet transactions", () => {
    const state = makeExampleBorrowSystemState()
    state.transactions.push({
      id: "tx-1",
      walletId: "ghost-wallet",
      kind: "borrow",
      amountUsd6: 1n,
      at: state.now,
    })

    expect(() => assertBorrowSystemInvariants(state)).toThrow("unknown wallet")
  })
})
