import { describe, expect, it } from "vitest"
import { formatBorrowLpSymbolLabel } from "@/app/lib/borrow-system/market-labels"

describe("borrow market labels", () => {
  it("formats LP symbols when visuals exist", () => {
    expect(
      formatBorrowLpSymbolLabel({
        display: {
          visuals: [{ symbol: "WETH" }, { symbol: "USDC" }],
        },
      }),
    ).toBe("WETH / USDC")
  })

  it("falls back when visuals are missing", () => {
    expect(formatBorrowLpSymbolLabel({ display: { name: "WETH / USDC" } })).toBe("WETH / USDC")
    expect(formatBorrowLpSymbolLabel(null)).toBe("LP")
  })

  it("keeps all tokens for a tri-token pool instead of truncating to two visuals", () => {
    expect(
      formatBorrowLpSymbolLabel({
        display: {
          name: "USDC / WBTC / ETH",
          visuals: [{ symbol: "WBTC" }, { symbol: "ETH" }],
        },
      }),
    ).toBe("USDC / WBTC / ETH")
  })
})
