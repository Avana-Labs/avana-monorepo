import { describe, expect, it } from "vitest"
import { debtBorrowAprPct, marketBorrowAprPct } from "@/app/lib/borrow-system/selectors"

const WAD = 10n ** 18n
const FIVE_PCT = WAD / 20n

describe("borrower rate", () => {
  it("is the base rate × (1 + the market's collateral risk)", () => {
    // Stable market: 400 bps of a 5% base rate is 5.2%.
    expect(marketBorrowAprPct(FIVE_PCT, 400)).toBeCloseTo(5.2)
    expect(marketBorrowAprPct(FIVE_PCT, 4_000)).toBeCloseTo(7)
  })

  it("uses the market's on-chain premium, not the local model's", () => {
    const model = () => {
      throw new Error("model premium read for a market with an on-chain premium")
    }
    expect(debtBorrowAprPct(FIVE_PCT, { listPremiumBps: 1_000 }, model)).toBeCloseTo(5.5)
  })

  it("falls back to the local model without a market premium", () => {
    expect(debtBorrowAprPct(FIVE_PCT, undefined, () => WAD / 100n)).toBeCloseTo(6)
    expect(debtBorrowAprPct(FIVE_PCT, { listPremiumBps: undefined }, () => 0n)).toBeCloseTo(5)
  })
})
