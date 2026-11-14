import { describe, expect, it } from "vitest"
import {
  borrowedAssetUsd6,
  repriceDebtValueUsd6,
  totalBorrowedUsd6,
} from "@/app/lib/credit-engine/borrowed-asset-valuation"
import { parseFixed } from "@/app/lib/credit-engine/units"

const tok = (n: string) => parseFixed(n, 18)
const usd6 = (n: string) => parseFixed(n, 6)

describe("borrowed-asset valuation — §7 (amount × own price, never LP)", () => {
  it("values 2 WBTC + 8,000 USDC at their own token prices → $136,000", () => {
    const wbtc = borrowedAssetUsd6(tok("2"), usd6("64000"))
    const usdc = borrowedAssetUsd6(tok("8000"), usd6("1"))
    expect(wbtc).toBe(usd6("128000"))
    expect(usdc).toBe(usd6("8000"))
    expect(
      totalBorrowedUsd6([
        { tokenAmountWad: tok("2"), priceUsd6: usd6("64000") },
        { tokenAmountWad: tok("8000"), priceUsd6: usd6("1") },
      ]),
    ).toBe(usd6("136000"))
  })

  it("zero / non-positive amounts and prices contribute nothing", () => {
    expect(borrowedAssetUsd6(0n, usd6("64000"))).toBe(0n)
    expect(borrowedAssetUsd6(tok("2"), 0n)).toBe(0n)
  })
})

describe("repriceDebtValueUsd6 — debt tracks the borrowed token's spot price (D2)", () => {
  it("is a no-op when the price is unchanged", () => {
    expect(repriceDebtValueUsd6(usd6("5000"), usd6("1900"), usd6("1900"))).toBe(usd6("5000"))
  })

  it("scales debt up when the borrowed asset appreciates (ETH 1900 → 2100)", () => {
    // $5,000 of ETH debt at $1,900 becomes $5,000 × 2100/1900 ≈ $5,526.32.
    const repriced = repriceDebtValueUsd6(usd6("5000"), usd6("1900"), usd6("2100"))
    expect(Number(repriced) / 1e6).toBeCloseTo(5000 * (2100 / 1900), 2)
  })

  it("shrinks stablecoin debt on a depeg (USDT 1.000 → 0.999)", () => {
    const repriced = repriceDebtValueUsd6(usd6("8000"), usd6("1"), usd6("0.999"))
    expect(Number(repriced) / 1e6).toBeCloseTo(7992, 2)
  })

  it("is a safe no-op for legacy positions with no captured borrow-time price", () => {
    expect(repriceDebtValueUsd6(usd6("5000"), undefined, usd6("2100"))).toBe(usd6("5000"))
    expect(repriceDebtValueUsd6(usd6("5000"), usd6("1900"), undefined)).toBe(usd6("5000"))
  })
})
