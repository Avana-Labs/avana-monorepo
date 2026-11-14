import { describe, expect, it } from "vitest"
import { getMultiplyMarketDetail } from "@/app/lib/multiply-detail"
import { resolveHeroContractLabel } from "@/app/borrow/_detail/lib/hero-chart-feeds"

describe("multiply detail about contract", () => {
  it("uses a lend-style copyable contract address in the hero", () => {
    const detail = getMultiplyMarketDetail("crvusd-usdt")!
    expect(detail.hero.venue).toBe("Avana Multiply")
    expect(detail.hero.explorerUrl).toMatch(/^https:\/\/etherscan\.io\/address\/0x[a-fA-F0-9]{40}$/)
    expect(resolveHeroContractLabel(detail.id, detail.hero.explorerUrl)).toMatch(
      /^0x[a-fA-F0-9]{4}\.\.\.[a-fA-F0-9]{4}$/,
    )
  })

  it("formats crvUSD pair labels and resolves the hero logo case-insensitively", () => {
    const detail = getMultiplyMarketDetail("crvusd-usdt")!
    expect(detail.hero.name).toBe("crvUSD / USDT")
    expect(detail.hero.visuals[0]?.symbol).toBe("crvUSD")
    expect(detail.hero.visuals[0]?.iconUrl).toMatch(/\/asset-icons\/crvusd\.png$/)
    expect(detail.hero.visuals[1]?.iconUrl).toMatch(/\/asset-icons\/usdt\.png$/)
  })

  it("mock builder yields empty About stats — contract rows injected by Convex overlay", () => {
    // Contract-address stats are no longer baked into the mock builder. The three
    // vault/token/riskManager/oracleRouter rows land in about.stats at Convex overlay time, via
    // getMultiplyMarketDetailFromConvex + api.contractAddresses.listMultiplyAddresses.
    // Verify the mock stays empty here so a regression that re-adds mock rows fails.
    const detail = getMultiplyMarketDetail("aave-gho")!
    expect(detail.about.stats).toEqual([])
  })

  it("uses slim key statistics, market rates, and risk parameters", () => {
    const detail = getMultiplyMarketDetail("aave-gho")!
    expect(detail.quickStats.map((stat) => stat.label)).toEqual([
      "Price",
      "Available Liquidity",
      "Profitability",
      "Reserve Factor",
    ])
    // Profitability / Net APY are the same leveraged return the landing APY column uses
    // (economics.estimatedMaxApy), not just the base supply APY.
    expect(detail.quickStats.find((stat) => stat.label === "Profitability")!.value).toBe("10.56%")
    expect(detail.marketRates.map((stat) => stat.label)).toEqual([
      "Supply APY",
      "Borrow APY",
      "Net APY",
      "Max Multiplier",
      "Collateral Factor",
      "Liquidation LTV",
    ])
    expect(detail.marketRates.find((stat) => stat.label === "Net APY")!.value).toBe("10.56%")
    expect(detail.marketRates.find((stat) => stat.label === "Max Multiplier")!.value).toBe("1.80x")
    expect(detail.about.governanceParameters?.parameters.map((parameter) => parameter.label)).toEqual([
      "Collateral factor",
      "Collateral risk",
      "Deposit capacity",
      "Liquidation penalty",
      "Borrow capacity",
      "Target health factor",
      "Liquidation threshold",
      "Oracle source",
    ])
    expect(detail.about.governanceParameters?.changelog.length).toBeGreaterThan(0)
  })
})
