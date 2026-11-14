import { describe, expect, it } from "vitest"
import { requiresOnboarding } from "@/app/lib/route-access"

describe("requiresOnboarding", () => {
  it.each(["/dashboard", "/dashboard/borrow", "/umbrella", "/umbrella/x", "/sandbox/transactions/0xabc"])(
    "locks %s behind onboarding",
    (pathname) => expect(requiresOnboarding(pathname)).toBe(true),
  )

  it.each([
    "/",
    "/ask",
    "/borrow",
    "/borrow/markets/uni-v2:eth-usdc",
    "/borrow/assets/dai",
    "/lend",
    "/lend/markets/usdc",
    "/multiply",
    "/multiply/markets/eth",
    "/actions/borrow/borrow",
    "/swap",
    "/support-center",
    "/onboarding",
  ])("leaves %s open", (pathname) => expect(requiresOnboarding(pathname)).toBe(false))

  it("matches whole path segments only", () => {
    expect(requiresOnboarding("/dashboards")).toBe(false)
    expect(requiresOnboarding("/umbrellas")).toBe(false)
  })
})
