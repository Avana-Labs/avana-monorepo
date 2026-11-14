import { describe, expect, it } from "vitest"
import { calculateClaimPreview, type HomeClaimPosition } from "@/app/lib/home-sim"

const visual = { symbol: "X", shortLabel: "X", bgClassName: "bg-x", textClassName: "text-x" }

const position: HomeClaimPosition = {
  id: "claim-eth-usdc",
  poolId: "pool-eth-usdc",
  name: "ETH / USDC",
  subtitle: "Uniswap",
  totalUsd: 111.1,
  breakdown: [
    { id: "eth", symbol: "ETH", amountLabel: "0.02 ETH", usdValue: 68.99, visual },
    { id: "usdc", symbol: "USDC", amountLabel: "42.11 USDC", usdValue: 42.11, visual },
  ],
}

describe("calculateClaimPreview", () => {
  it("p1-28: itemized token breakdown reconciles without a Fees reward leg", () => {
    const preview = calculateClaimPreview(
      [position],
      { [position.id]: position.totalUsd },
      { [position.id]: true },
      null,
    )

    const rowsSum = Object.values(preview.tokenTotals).reduce((sum, value) => sum + value, 0)
    expect(rowsSum).toBeCloseTo(preview.selectedTotalUsd, 6)
    expect(rowsSum).toBeCloseTo(111.1, 6)
    expect(preview.effectiveClaimUsd).toBeCloseTo(111.1, 6)
    expect(preview.tokenTotals.Fees).toBeUndefined()
  })

  it("p1-28: drops Fees symbol even if present in breakdown input", () => {
    const withFees: HomeClaimPosition = {
      ...position,
      breakdown: [...position.breakdown, { id: "fees", symbol: "Fees", amountLabel: "$30.90", usdValue: 30.9, visual }],
    }
    const preview = calculateClaimPreview([withFees], { [withFees.id]: 111.1 }, { [withFees.id]: true }, null)
    expect(preview.tokenTotals.Fees).toBeUndefined()
    expect(preview.tokenTotals.ETH).toBeCloseTo(68.99, 6)
    expect(preview.tokenTotals.USDC).toBeCloseTo(42.11, 6)
  })

  it("excludes unselected positions", () => {
    const preview = calculateClaimPreview(
      [position],
      { [position.id]: position.totalUsd },
      { [position.id]: false },
      null,
    )
    expect(preview.hasSelection).toBe(false)
    expect(preview.selectedTotalUsd).toBe(0)
    expect(Object.keys(preview.tokenTotals)).toHaveLength(0)
  })
})
