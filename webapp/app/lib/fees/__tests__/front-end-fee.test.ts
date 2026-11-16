import { describe, expect, it } from "vitest"
import { DEFAULT_FEE_RULES, quoteFee } from "@/convex/lib/fees"
import { feeActionForKind, frontendFeeBps, frontendFeeUsd, statedFeeBps } from "@/app/lib/fees/front-end-fee"

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
