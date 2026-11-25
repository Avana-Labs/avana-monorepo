import { afterEach, describe, expect, it } from "vitest"
import { DEFAULT_FEE_RULES, quoteFee } from "@/convex/lib/fees"
import {
  feeActionForKind,
  frontendFeeAmount,
  frontendFeeBps,
  frontendFeeRules,
  frontendFeeUsd,
  setFrontendFeeRules,
  setFrontendMemberDiscount,
  statedFeeBps,
} from "@/app/lib/fees/front-end-fee"

describe("front-end fee (Q-409)", () => {
  it("is the same amount quoteFee gives, rounded down", () => {
    const fromConvex = quoteFee(DEFAULT_FEE_RULES, {
      action: "supply",
      basis: { kind: "amount", amount: 1_234_567_891n, decimals: 6, priceUsd8: 100_000_000n },
      gas: { gasUnits: 0n, baseFeeWei: 0n, priorityFeeWei: 0n, l1FeeWei: 0n, nativeUsd8: 0n },
    })
    expect(frontendFeeUsd("supply", 1234.567891)).toBe(Number(fromConvex.feeAmount) / 1e6)
    expect(frontendFeeUsd("supply", 1234.567891)).toBe(1.234567)
  })

  it("values pledge and withdraw collateral on the position's USD value", () => {
    expect(frontendFeeUsd("pledge", 43_750)).toBe(43.75)
    expect(frontendFeeUsd("withdrawCollateral", 1000)).toBe(1)
  })

  it("maps action page kinds to Q-409 actions, with no fee for claim", () => {
    expect(
      ["borrow", "repay", "supply", "pledge", "remove", "deposit", "withdraw", "claim"].map(feeActionForKind),
    ).toEqual(["borrow", "repay", "pledge", "pledge", "withdrawCollateral", "supply", "withdraw", null])
    expect(frontendFeeBps("claim")).toBe(0)
    expect(frontendFeeBps("swap")).toBe(10)
    expect(statedFeeBps()).toBe(10)
  })
})

describe("member fee discount", () => {
  afterEach(() => {
    setFrontendMemberDiscount(0)
    setFrontendFeeRules(DEFAULT_FEE_RULES)
  })

  it("lowers the stated rate, the fee row and the transferred amount from the same rules", () => {
    setFrontendMemberDiscount(3)
    expect(statedFeeBps()).toBe(7)
    expect(frontendFeeBps("supply")).toBe(7)
    expect(frontendFeeUsd("supply", 10_000)).toBe(7)
    expect(frontendFeeAmount("supply", 10_000_000_000n, 6)).toBe(7_000_000n)
    expect(frontendFeeAmount("swap", 10_000_000_000n, 6)).toBe(7_000_000n)
  })

  it("keeps the discount when the Convex rules load after it, and drops it for a guest", () => {
    setFrontendMemberDiscount(2)
    setFrontendFeeRules({ ...DEFAULT_FEE_RULES, defaultBps: 12 })
    expect(frontendFeeBps("repay")).toBe(10)
    expect(frontendFeeRules().memberDiscountBps).toBe(2)
    setFrontendMemberDiscount(0)
    expect(frontendFeeBps("repay")).toBe(12)
    expect(frontendFeeRules().memberDiscountBps).toBeUndefined()
  })

  it("ignores a discount that is not a whole positive number of bps", () => {
    for (const bps of [-1, 0.5, Number.NaN]) {
      setFrontendMemberDiscount(bps)
      expect(frontendFeeBps("supply")).toBe(10)
    }
  })
})
