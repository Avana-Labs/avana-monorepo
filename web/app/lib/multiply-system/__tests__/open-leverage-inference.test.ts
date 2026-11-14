import { describe, expect, it } from "vitest"
import { buildMultiplyActivityHistory, inferOpenedLeverageByMarket } from "@/app/lib/multiply-system/read-model"
import type { MultiplyTransactionHistoryItem } from "@/app/lib/multiply-system/contracts"

describe("inferOpenedLeverageByMarket", () => {
  it("infers a market's opened leverage from a later close's pre-unwind leverage", () => {
    const map = inferOpenedLeverageByMarket([
      { product: "multiply", kind: "multiply", marketSlug: "aave-gho", multiplierBefore: 1 },
      { product: "multiply", kind: "close", marketSlug: "aave-gho", multiplierBefore: 2 },
    ])
    expect(map.get("aave-gho")).toBe(2)
  })

  it("uses the peak pre-unwind leverage across multiple unwinds", () => {
    const map = inferOpenedLeverageByMarket([
      { product: "multiply", kind: "deleverage", marketSlug: "steth-eth", multiplierBefore: 3 },
      { product: "multiply", kind: "close", marketSlug: "steth-eth", multiplierBefore: 2 },
    ])
    expect(map.get("steth-eth")).toBe(3)
  })

  it("returns nothing for a market that only has an open (no unwind to infer from)", () => {
    const map = inferOpenedLeverageByMarket([
      { product: "multiply", kind: "multiply", marketSlug: "dai-gho", multiplierBefore: 1 },
    ])
    expect(map.has("dai-gho")).toBe(false)
  })

  it("ignores non-multiply rows and rows without a market or a >1 leverage", () => {
    const map = inferOpenedLeverageByMarket([
      { product: "borrow", kind: "close", marketSlug: "dai-gho", multiplierBefore: 2 },
      { product: "multiply", kind: "close", marketSlug: null, multiplierBefore: 2 },
      { product: "multiply", kind: "close", marketSlug: "dai-gho", multiplierBefore: 1 },
    ])
    expect(map.size).toBe(0)
  })
})

describe("buildMultiplyActivityHistory open label", () => {
  const base = {
    id: "tx-open",
    intentId: "intent-open",
    walletId: "wallet-1",
    marketId: "aave-gho",
    status: "success" as const,
    amountUsd: 41_700,
    simulated: true,
    timestamp: 1_700_000_000_000,
    hash: "0xopen",
  }

  it("renders an open with a recovered resulting leverage as '1.00x → 2.00x' (not '1.00x → 1.00x')", () => {
    const item: MultiplyTransactionHistoryItem = {
      ...base,
      kind: "multiply",
      // The session hydration injects multiplierAfter = the inferred opened leverage (2) even after
      // the position has closed; the label must reflect that, not a flat 1.00x → 1.00x.
      multiplierBefore: 1,
      multiplierAfter: 2,
    }
    const [row] = buildMultiplyActivityHistory("wallet-1", [item])
    expect(row?.kind).toBe("open")
    expect(row?.secondaryLabel).toContain("1.00x → 2.00x")
  })
})
