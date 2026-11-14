import { describe, expect, it } from "vitest"
import { lendDepositSelectItems } from "@/app/lib/action-system/resolve-lend-context"
import { buildMockLendSystemState } from "@/app/lib/lend-system/mock"

describe("resolve lend context", () => {
  it("only lists deposit assets held in the connected wallet", () => {
    const session = { state: buildMockLendSystemState("demo-wallet") }
    const items = lendDepositSelectItems(session, "demo-wallet")

    expect(items.map((item) => item.symbol).sort()).toEqual(["ETH", "USDC", "USDT"])
    expect(items.find((item) => item.symbol === "USDC")?.sublabel).toBe("Stable · Core")
    expect(items.some((item) => item.symbol === "cbBTC")).toBe(false)
  })

  it("formats the picker APY as a percent (not a fraction)", () => {
    const session = { state: buildMockLendSystemState("demo-wallet") }
    const items = lendDepositSelectItems(session, "demo-wallet")
    const usdc = items.find((item) => item.symbol === "USDC")

    const usdcSupplyApy = session.state.markets.usdc!.supplyApy
    // supplyApy is a fraction; the label must be its percent (e.g. 4.85%), not 0.05%.
    expect(usdc?.trailingSublabel).toBe(`${(usdcSupplyApy * 100).toFixed(2)}% APY`)
    expect(usdc?.trailingSublabel).not.toBe(`${usdcSupplyApy.toFixed(2)}% APY`)
  })
})
