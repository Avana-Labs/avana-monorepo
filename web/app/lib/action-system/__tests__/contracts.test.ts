import { describe, expect, it } from "vitest"
import { actionPagePath, getActionDescriptor, resolveActionCloseHref } from "@/app/lib/action-system/contracts"

describe("action-system contracts", () => {
  it("defines descriptors for all 10 product actions", () => {
    const paths = [
      getActionDescriptor("borrow", "borrow"),
      getActionDescriptor("borrow", "repay"),
      getActionDescriptor("borrow", "supply"),
      getActionDescriptor("borrow", "remove"),
      getActionDescriptor("borrow", "claim"),
      getActionDescriptor("lend", "deposit"),
      getActionDescriptor("lend", "withdraw"),
      getActionDescriptor("multiply", "multiply"),
      getActionDescriptor("multiply", "deleverage"),
      getActionDescriptor("rewards", "claim"),
    ]

    expect(paths).toHaveLength(10)
    expect(new Set(paths.map((entry) => `${entry.product}:${entry.kind}`)).size).toBe(10)
  })

  it("builds stable action page paths", () => {
    expect(actionPagePath("borrow", "borrow", { asset: "usdc" })).toBe("/actions/borrow/borrow?asset=usdc")
    expect(actionPagePath("lend", "deposit")).toBe("/actions/lend/deposit")
    expect(resolveActionCloseHref("multiply")).toBe("/multiply")
    expect(resolveActionCloseHref("borrow", "//evil.example")).toBe("/borrow")
    expect(resolveActionCloseHref("multiply", "/multiply/market/aave-gho")).toBe("/multiply/markets/aave-gho")
    expect(resolveActionCloseHref("borrow", "/borrow/pool/uni-v3-bluechip-weth-usdc")).toBe(
      "/borrow/markets/uni-v3-bluechip-weth-usdc",
    )
    expect(resolveActionCloseHref("borrow", "/borrow/asset/usdc")).toBe("/borrow/assets/usdc")
  })

  it("uses Avana action configure subtitles", () => {
    expect(getActionDescriptor("borrow", "borrow").subtitle).toContain("Configure and review")
    expect(getActionDescriptor("lend", "withdraw").subtitle).toContain("Configure and review")
  })
})
