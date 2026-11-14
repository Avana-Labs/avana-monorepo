import { describe, expect, it } from "vitest"
import {
  mapBorrowRewardsClaimPreviewToActionUi,
  mapRewardsClaimPreviewToActionUi,
} from "@/app/lib/action-system/adapters/rewards-preview-mapper"

describe("rewards preview mappers", () => {
  it("maps rewards claim summary without redundant metric rows", () => {
    const ui = mapRewardsClaimPreviewToActionUi({
      allowed: true,
      claimUsd: 120,
      marketLabel: "Avana rewards",
      claimableTaskCount: 3,
      tokenBreakdown: [
        { symbol: "AVA", amount: 80 },
        { symbol: "AVA", amount: 40 },
      ],
    })

    expect(ui.amountLabel).toBe("AVA")
    expect(ui.rateValue).toBe("3 quests")
    expect(ui.marketValue).toBe("")
    expect(ui.metrics).toEqual([])
  })

  it("maps borrow-side claim per token", () => {
    const ui = mapBorrowRewardsClaimPreviewToActionUi({
      allowed: true,
      claimUsd: 55,
      marketLabel: "WETH · Core",
      tokenTotals: { WETH: 30, USDC: 25 },
    })

    expect(ui.amountValue).toBe("$55.00")
    expect(ui.assetLabel).toBe("WETH · Core")
    expect(ui.metrics.map((row) => row.label)).toEqual(["WETH", "USDC"])
  })

  it("keeps cents on a claim total over $100 so it reconciles with its rows (#25)", () => {
    const ui = mapBorrowRewardsClaimPreviewToActionUi({
      allowed: true,
      claimUsd: 111.1,
      marketLabel: "WETH · Core",
      tokenTotals: { WETH: 68.99, USDC: 42.11 },
    })
    // $68.99 + $42.11 = $111.10 — not a cents-dropping "$111".
    expect(ui.amountValue).toBe("$111.10")
    expect(ui.rateValue).toBe("$111.10")
    expect(ui.metrics.map((row) => row.value)).toEqual(["$68.99", "$42.11"])
  })
})
