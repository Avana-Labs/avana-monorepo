import { describe, expect, it } from "vitest"
import { createExecutionFingerprint } from "@/app/lib/borrow-system/execution-guard"
import type { TransactionIntent } from "@/app/lib/borrow-system/contracts"

function intent(overrides: Partial<TransactionIntent>): TransactionIntent {
  return {
    id: "intent-1",
    actionType: "borrow",
    walletId: "0xabc",
    marketId: "uni-v3-weth-usdc",
    assetId: "uni-v2:usdc",
    amountUsd6: 1_000_000n,
    requestedAt: 0,
    simulated: true,
    ...overrides,
  }
}

describe("createExecutionFingerprint (double-submit dedup, L-15)", () => {
  it("matches two submits with the SAME content but different intent ids", () => {
    // createIntent mints a fresh id per click; the dedup must still collapse an identical
    // rapid re-submit (it previously keyed on id and never matched).
    const a = createExecutionFingerprint(intent({ id: "intent-1" }))
    const b = createExecutionFingerprint(intent({ id: "intent-2" }))
    expect(a).toBe(b)
  })

  it("differs when the amount or action content differs", () => {
    const base = createExecutionFingerprint(intent({}))
    expect(createExecutionFingerprint(intent({ amountUsd6: 2_000_000n }))).not.toBe(base)
    expect(createExecutionFingerprint(intent({ actionType: "repay" }))).not.toBe(base)
    expect(createExecutionFingerprint(intent({ marketId: "other" }))).not.toBe(base)
  })
})
