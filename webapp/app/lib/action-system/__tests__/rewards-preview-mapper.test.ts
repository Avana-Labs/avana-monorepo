import { describe, expect, it } from "vitest"
import { getActionDescriptor, isValidAction, resolveActionCloseHref } from "@/app/lib/action-system/contracts"
import { mapRewardsRedeemPreviewToActionUi } from "@/app/lib/action-system/adapters/rewards-preview-mapper"

const labels = { points: "1,300 pts", discount: "2 bps off", validUntil: "12/16/2026", pointsLeft: "300 pts" }

describe("the redeem action", () => {
  it("is the rewards claim action page", () => {
    expect(isValidAction("rewards", "claim")).toBe(true)
    expect(isValidAction("rewards", "deposit")).toBe(false)
    expect(getActionDescriptor("rewards", "claim")).toMatchObject({ title: "Redeem points", primaryVerb: "Redeem" })
    expect(resolveActionCloseHref("rewards")).toBe("/dashboard?tab=rewards")
    expect(resolveActionCloseHref("rewards", "/dashboard?tab=wallet")).toBe("/dashboard?tab=wallet")
  })

  it("previews the points spent, the discount, when it ends and the points left", () => {
    const ui = mapRewardsRedeemPreviewToActionUi({ allowed: true, points: 1000, labels })
    expect(ui).toMatchObject({
      allowed: true,
      amountValue: "1000",
      rateLabel: "Fee discount",
      rateValue: "2 bps off",
      blockedReason: null,
    })
    expect(ui.metrics.map((m) => [m.label, m.value])).toEqual([
      ["Valid until", "12/16/2026"],
      ["Points left", "300 pts"],
    ])
    expect(ui.platformFeeLabel).toBe("~ $0.00")
  })

  it("blocks with the reason and shows no metrics when nothing can be redeemed", () => {
    const ui = mapRewardsRedeemPreviewToActionUi({
      allowed: false,
      points: 1000,
      labels,
      blockedReason: "You already hold the largest discount allowed.",
    })
    expect(ui).toMatchObject({ allowed: false, blockedReason: "You already hold the largest discount allowed." })
    expect(ui.metrics).toEqual([])
  })
})
