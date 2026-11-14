import { describe, expect, it } from "vitest"
import { evaluateBorrowAction, parseFixed } from "@/app/lib/credit-engine"
import { EXAMPLE_UNI_MARKET_ID, EXAMPLE_UNI_USDC_ASSET_ID, makeExampleBorrowSystemState } from "./fixtures"

describe("evaluateBorrowAction", () => {
  it("returns the same end state for dry-run and commit modes", () => {
    const state = makeExampleBorrowSystemState()
    const action = {
      type: "borrow" as const,
      walletId: "wallet-1",
      marketId: EXAMPLE_UNI_MARKET_ID,
      assetId: EXAMPLE_UNI_USDC_ASSET_ID,
      amountUsd6: parseFixed("300", 6),
    }

    const dryRun = evaluateBorrowAction(state, action, "dry-run")
    const commit = evaluateBorrowAction(state, action, "commit")

    expect(dryRun.transactions.at(-1)?.kind).toBe("borrow")
    expect(commit.transactions.at(-1)?.kind).toBe("borrow")
    expect(state.transactions.length).toBe(0)
  })
})
