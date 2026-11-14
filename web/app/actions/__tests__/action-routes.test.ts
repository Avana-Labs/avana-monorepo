import { describe, expect, it } from "vitest"
import { actionPagePath, getActionDescriptor } from "@/app/lib/action-system/contracts"

const ACTION_ROUTES = [
  ["borrow", "borrow"],
  ["borrow", "repay"],
  ["borrow", "supply"],
  ["borrow", "remove"],
  ["borrow", "claim"],
  ["lend", "deposit"],
  ["lend", "withdraw"],
  ["multiply", "multiply"],
  ["multiply", "deleverage"],
  ["multiply", "close"],
  ["rewards", "claim"],
  ["umbrella", "stake"],
  ["umbrella", "claim"],
  ["umbrella", "cooldown"],
  ["umbrella", "unstake"],
] as const

describe("action routes", () => {
  it.each(ACTION_ROUTES)("registers descriptor for %s/%s", (product, kind) => {
    const descriptor = getActionDescriptor(product, kind)
    expect(descriptor.title.length).toBeGreaterThan(0)
    expect(descriptor.primaryVerb.length).toBeGreaterThan(0)
  })

  it.each(ACTION_ROUTES)("builds route path for %s/%s", (product, kind) => {
    expect(actionPagePath(product, kind)).toBe(`/actions/${product}/${kind}`)
    expect(actionPagePath(product, kind, { asset: "usdc", return: "/borrow" })).toContain("asset=usdc")
    expect(actionPagePath(product, kind, { asset: "usdc", return: "/borrow" })).toContain("return=%2Fborrow")
  })
})
