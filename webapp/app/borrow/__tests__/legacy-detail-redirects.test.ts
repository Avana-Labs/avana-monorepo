import { describe, expect, it, vi } from "vitest"

const redirect = vi.fn()
vi.mock("next/navigation", () => ({ redirect: (href: string) => redirect(href) }))

describe("older borrow detail links", () => {
  it("send /borrow/asset/[id] to the asset detail page", async () => {
    const { default: Page } = await import("@/app/borrow/asset/[assetId]/page")
    await Page({ params: Promise.resolve({ assetId: "uni-v3-bluechip%3Ausdc" }) })
    expect(redirect).toHaveBeenLastCalledWith("/borrow/assets/uni-v3-bluechip%3Ausdc")
  })

  it("send /borrow/pool/[id] to the market detail page", async () => {
    const { default: Page } = await import("@/app/borrow/pool/[poolId]/page")
    await Page({ params: Promise.resolve({ poolId: "uni-v3-bluechip-weth-usdc" }) })
    expect(redirect).toHaveBeenLastCalledWith("/borrow/markets/uni-v3-bluechip-weth-usdc")
  })
})
