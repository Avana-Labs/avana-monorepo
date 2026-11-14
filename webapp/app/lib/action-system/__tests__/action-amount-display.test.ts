import { describe, expect, it } from "vitest"
import { resolveActionAmountCardProps } from "@/app/lib/action-system/action-amount-display"

describe("resolveActionAmountCardProps", () => {
  it("uses explicit preview fields for LP supply amounts", () => {
    expect(
      resolveActionAmountCardProps({
        amountLabel: "$2,000.00",
        amountValue: "2000",
        assetLabel: "WETH / USDC",
        assetSymbol: "WETH",
        borrowSymbol: "USDC",
      }),
    ).toEqual({
      amount: "2000",
      assetLabel: "WETH / USDC",
      assetSymbol: "WETH",
      borrowSymbol: "USDC",
    })
  })

  it("parses legacy pair labels without splitting the slash away", () => {
    expect(
      resolveActionAmountCardProps({
        amountLabel: "2000 EURC / USDC",
      }),
    ).toEqual({
      amount: "2000",
      assetLabel: "EURC / USDC",
      assetSymbol: "EURC",
      borrowSymbol: "USDC",
    })
  })
})
